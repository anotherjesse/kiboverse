import SwiftUI

struct ReplyAutoplayGate: Equatable {
    let sceneIsActive: Bool
    let systemPlaybackSuspended: Bool
    let captureIsActive: Bool
    let overlayIsPresented: Bool

    var allowsPlayback: Bool {
        sceneIsActive
            && !systemPlaybackSuspended
            && !captureIsActive
            && !overlayIsPresented
    }
}

struct ReplyCommandClaim: Equatable {
    fileprivate let generation: UUID
    fileprivate let destination: KiboDestination
}

/// Owns the view-local command epoch and the one reply that may autoplay.
/// Teardown transitions invalidate command completions before audio objects
/// publish their own stop notifications.
struct ReplyLifecycle: Equatable {
    private var generation = UUID()
    private(set) var isVisible = false
    private(set) var isActive = false
    private(set) var awaitedTurnID: String?
    private(set) var awaitedDestination: KiboDestination?
    private(set) var attemptedSpeechEventSeq: UInt64?

    var allowsPlayback: Bool { isVisible && isActive }

    mutating func appear(isActive: Bool) {
        generation = UUID()
        isVisible = true
        self.isActive = isActive
    }

    mutating func beginCommand(destination: KiboDestination) -> ReplyCommandClaim? {
        guard isVisible, isActive else { return nil }
        generation = UUID()
        return ReplyCommandClaim(generation: generation, destination: destination)
    }

    func accepts(
        _ claim: ReplyCommandClaim,
        destination: KiboDestination?
    ) -> Bool {
        isVisible
            && isActive
            && generation == claim.generation
            && destination == claim.destination
    }

    mutating func awaitReply(to turnID: String, destination: KiboDestination) {
        awaitedTurnID = turnID
        awaitedDestination = destination
        attemptedSpeechEventSeq = nil
    }

    mutating func markPlaybackAttempt(speechEventSeq: UInt64) {
        attemptedSpeechEventSeq = speechEventSeq
    }

    /// Preserve which reply the user asked for, but allow its durable speech
    /// event to start a fresh transport when playback becomes safe again.
    mutating func suspendPlayback() {
        attemptedSpeechEventSeq = nil
    }

    mutating func clearPlayback() {
        awaitedTurnID = nil
        awaitedDestination = nil
        attemptedSpeechEventSeq = nil
    }

    mutating func selectionChanged() {
        generation = UUID()
        clearPlayback()
    }

    mutating func becomeInactive() {
        generation = UUID()
        isActive = false
        suspendPlayback()
    }

    mutating func becomeActive() {
        isActive = isVisible
    }

    mutating func disappear() {
        generation = UUID()
        isVisible = false
        isActive = false
        clearPlayback()
    }
}

/// The single submit + reply-autoplay code path, shared by
/// ConversationDetailView and TalkModeView. Extracted from the old TalkView:
/// asking Kibo goes through `startSubmit()`, and the spoken reply autoplays
/// once the gate allows it — never from a screen sitting under an overlay.
@MainActor
final class ReplySession: ObservableObject {
    private var lifecycle = ReplyLifecycle()
    private var commandTask: Task<Void, Never>?
    private weak var store: AppStore?
    private weak var audio: AudioCoordinator?
    private var sceneIsActive = false
    private var overlayIsPresented = false
    private var isCoveredByOverlay = false

    func connect(store: AppStore, audio: AudioCoordinator) {
        self.store = store
        self.audio = audio
    }

    func updateGate(sceneIsActive: Bool, overlayIsPresented: Bool) {
        self.sceneIsActive = sceneIsActive
        self.overlayIsPresented = overlayIsPresented
    }

    func appear(sceneIsActive: Bool) {
        self.sceneIsActive = sceneIsActive
        if isCoveredByOverlay {
            // Re-appearing because the full-screen cover came down, not a
            // fresh presentation: keep the in-flight ask and awaited reply
            // so suppressed autoplay can resume here.
            isCoveredByOverlay = false
            playAwaitedReplyIfReady()
            return
        }
        lifecycle.appear(isActive: sceneIsActive)
    }

    /// The screen was covered by the full-screen talk mode, not dismissed.
    /// Nothing is torn down: the overlay gate already suppresses autoplay,
    /// an in-flight ask keeps running so its reply can play after the cover
    /// dismisses, and the audio session is left alone — stopping it here
    /// would kill a hold just begun on the cover's own mic.
    func coveredByOverlay() {
        isCoveredByOverlay = true
    }

    func sceneBecameInactive() {
        lifecycle.becomeInactive()
        cancelCommand()
        audio?.stopForInactivity()
    }

    func sceneBecameActive() {
        lifecycle.becomeActive()
        if let audio {
            Task { await audio.prepare() }
        }
        playAwaitedReplyIfReady()
    }

    /// Invalidate every UI-owned completion before stop notifications can
    /// cause another autoplay evaluation.
    func destinationChanged() {
        lifecycle.selectionChanged()
        cancelCommand()
        audio?.stop()
    }

    func suspendPlayback() {
        lifecycle.suspendPlayback()
    }

    func disappear() {
        lifecycle.disappear()
        cancelCommand()
        audio?.stop()
    }

    func beginHold() {
        audio?.beginHold()
    }

    func endHold() {
        guard let store, let audio else { return }
        if let recording = audio.endHold() {
            store.queueRecording(recording)
        }
        playAwaitedReplyIfReady()
    }

    /// Discard the active capture without saving — a swipe-up flick asks
    /// with what was already pending instead of recording.
    func cancelHold() {
        audio?.cancelHold()
        playAwaitedReplyIfReady()
    }

    func startSubmit() {
        startSubmit(afterCaptureEnded: false)
    }

    /// `afterCaptureEnded` skips the capture-state guards: a swipe-up release
    /// just ended (or discarded) the hold itself, and the recorder's
    /// published state may not have settled yet on this exact tick.
    func startSubmit(afterCaptureEnded: Bool) {
        guard let store, let audio else { return }
        // Guard here instead of relying on .disabled so a stale tap during a
        // push-to-talk cycle can never double-submit.
        if !afterCaptureEnded {
            guard !audio.isRecording, !audio.isStarting else { return }
        }
        guard !store.isAskingKibo,
              let destination = store.requestDestination else { return }
        commandTask?.cancel()
        guard let claim = lifecycle.beginCommand(destination: destination) else { return }
        lifecycle.clearPlayback()
        audio.resumeAutomaticPlayback()
        commandTask = Task { [weak self, weak store] in
            guard let self, let store, !Task.isCancelled,
                  self.lifecycle.accepts(claim, destination: store.requestDestination) else { return }
            // A swipe-up ask fires the instant the clip is queued: wait for
            // its upload so the turn includes everything just said.
            await store.waitForRecordingTasks()
            guard !Task.isCancelled,
                  self.lifecycle.accepts(claim, destination: store.requestDestination) else { return }
            let turnID = await store.submitTurn()
            guard !Task.isCancelled,
                  self.lifecycle.accepts(claim, destination: store.requestDestination) else { return }
            self.commandTask = nil
            guard let turnID else { return }
            self.lifecycle.awaitReply(to: turnID, destination: claim.destination)
            self.playAwaitedReplyIfReady()
        }
    }

    func playAwaitedReplyIfReady() {
        guard let store, let audio else { return }
        let gate = ReplyAutoplayGate(
            sceneIsActive: sceneIsActive && lifecycle.allowsPlayback,
            systemPlaybackSuspended: audio.automaticPlaybackSuspended,
            captureIsActive: audio.isHolding || audio.isRecording || audio.isStarting,
            overlayIsPresented: overlayIsPresented
        )
        guard gate.allowsPlayback else { return }
        guard let turnID = lifecycle.awaitedTurnID,
              let destination = lifecycle.awaitedDestination,
              destination == store.requestDestination else { return }
        switch store.events.replyAutoPlayAction(
            for: turnID,
            attemptedSpeechEventSeq: lifecycle.attemptedSpeechEventSeq,
            loadingID: audio.loadingID,
            playingID: audio.playingID,
            lastFinishedID: audio.lastFinishedID
        ) {
        case let .startPlayback(speechEventSeq):
            lifecycle.markPlaybackAttempt(speechEventSeq: speechEventSeq)
            audio.playReply(turnID: turnID, destination: destination, store: store)
        case .complete:
            lifecycle.clearPlayback()
        case .failed:
            let playbackID = PlaybackID.reply(turnID)
            lifecycle.clearPlayback()
            if audio.loadingID == playbackID || audio.playingID == playbackID {
                audio.stopReply()
            }
        case .wait:
            break
        }
    }

    private func cancelCommand() {
        commandTask?.cancel()
        commandTask = nil
    }
}

/// Installs the lifecycle wiring a screen needs for its ReplySession: gate
/// updates, autoplay re-evaluation on audio/store changes, teardown on
/// destination change, scene inactivity, and disappearance.
struct ReplySessionDriver: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    let session: ReplySession
    let overlayIsPresented: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                session.connect(store: store, audio: audio)
                session.updateGate(
                    sceneIsActive: scenePhase == .active,
                    overlayIsPresented: overlayIsPresented
                )
                session.appear(sceneIsActive: scenePhase == .active)
            }
            .task { await audio.prepare() }
            .onChange(of: store.events) { _, _ in session.playAwaitedReplyIfReady() }
            .onChange(of: audio.loadingID) { _, _ in session.playAwaitedReplyIfReady() }
            .onChange(of: audio.playingID) { _, _ in session.playAwaitedReplyIfReady() }
            .onChange(of: audio.lastFinishedID) { _, _ in session.playAwaitedReplyIfReady() }
            .onChange(of: audio.isHolding) { _, _ in session.playAwaitedReplyIfReady() }
            .onChange(of: audio.automaticPlaybackSuspended) { _, suspended in
                if suspended { session.suspendPlayback() }
                else { session.playAwaitedReplyIfReady() }
            }
            .onChange(of: overlayIsPresented) { _, presented in
                session.updateGate(
                    sceneIsActive: scenePhase == .active,
                    overlayIsPresented: presented
                )
                if !presented { session.playAwaitedReplyIfReady() }
            }
            .onChange(of: store.requestDestination) { _, _ in
                session.destinationChanged()
            }
            .onChange(of: scenePhase) { _, phase in
                session.updateGate(
                    sceneIsActive: phase == .active,
                    overlayIsPresented: overlayIsPresented
                )
                if phase != .active {
                    session.sceneBecameInactive()
                } else {
                    session.sceneBecameActive()
                }
            }
            .onDisappear {
                if overlayIsPresented {
                    session.coveredByOverlay()
                } else {
                    session.disappear()
                }
            }
    }
}

extension View {
    func replySessionDriver(
        _ session: ReplySession,
        overlayIsPresented: Bool = false
    ) -> some View {
        modifier(ReplySessionDriver(
            session: session,
            overlayIsPresented: overlayIsPresented
        ))
    }
}
