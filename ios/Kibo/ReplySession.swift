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

/// The single submit + reply-autoplay code path, shared by
/// ConversationDetailView and TalkModeView. Extracted from the old TalkView:
/// asking Kibo goes through `startSubmit()`, and the spoken reply autoplays
/// once the gate allows it — never from a screen sitting under an overlay.
///
/// The command epoch/visibility lives in `ReplyCommandScope`; the awaited
/// reply and its afterglow live in `ReplyPlaybackIntent`. `intent` is
/// `@Published` because `CenterState.derive` reads `intent.finishedTurnID`
/// and mutations happen inside audio `.onChange` handlers that must re-render.
@MainActor
final class ReplySession: ObservableObject {
    @Published private(set) var intent = ReplyPlaybackIntent()
    private var scope = ReplyCommandScope()
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
        scope.appear(isActive: sceneIsActive)
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
        scope.setActive(false)
        intent.suspendPlayback()
        cancelCommand()
        audio?.stopForInactivity()
    }

    func sceneBecameActive() {
        scope.setActive(true)
        if let audio {
            Task { await audio.prepare() }
        }
        playAwaitedReplyIfReady()
    }

    /// Invalidate every UI-owned completion before stop notifications can
    /// cause another autoplay evaluation.
    func destinationChanged() {
        scope.selectionChanged()
        intent.clear()
        cancelCommand()
        audio?.stop()
    }

    func suspendPlayback() {
        intent.suspendPlayback()
    }

    func disappear() {
        scope.disappear()
        intent.clear()
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
        guard let claim = scope.beginCommand(destination: destination) else { return }
        intent.clear()
        audio.resumeAutomaticPlayback()
        commandTask = Task { [weak self, weak store] in
            guard let self, let store, !Task.isCancelled,
                  self.scope.accepts(claim, destination: store.requestDestination) else { return }
            // A swipe-up ask fires the instant the clip is queued: wait for
            // its upload so the turn includes everything just said.
            await store.waitForRecordingTasks()
            guard !Task.isCancelled,
                  self.scope.accepts(claim, destination: store.requestDestination) else { return }
            let turnID = await store.submitTurn()
            guard !Task.isCancelled,
                  self.scope.accepts(claim, destination: store.requestDestination) else { return }
            self.commandTask = nil
            guard let turnID else { return }
            self.intent.awaitReply(to: turnID, destination: claim.destination)
            self.playAwaitedReplyIfReady()
        }
    }

    func playAwaitedReplyIfReady() {
        guard let store, let audio else { return }
        let gate = ReplyAutoplayGate(
            sceneIsActive: sceneIsActive && scope.allowsPlayback,
            systemPlaybackSuspended: audio.automaticPlaybackSuspended,
            captureIsActive: audio.isHolding || audio.isRecording || audio.isStarting,
            overlayIsPresented: overlayIsPresented
        )
        guard gate.allowsPlayback else { return }
        guard let destination = intent.awaitedDestination,
              destination == store.requestDestination else { return }
        // The phone never sets the retry fence, so it supplies no revision.
        switch intent.advance(
            events: store.events,
            loadingID: audio.loadingID,
            playingID: audio.playingID,
            lastFinishedID: audio.lastFinishedID
        ) {
        case let .play(turnID, destination, _):
            audio.playReply(turnID: turnID, destination: destination, store: store)
        case .stopPlayback:
            audio.stopReply()
        case .none:
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
