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

struct TalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @State private var replyLifecycle = ReplyLifecycle()
    @State private var replyCommandTask: Task<Void, Never>?
    @State private var showingSettings = false
    @State private var recordingPulse = false

    var body: some View {
        VStack(spacing: 0) {
            selectionBar
            GeometryReader { geometry in
                let buttonDiameter = min(220.0, max(180.0, geometry.size.height * 0.34))
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Text(audio.isRecording ? "Listening…" : "Push to talk")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(audio.isRecording ? "Release when you’re finished" : "Hold the button while you speak")
                            .foregroundStyle(.secondary)
                        Text(audio.recordingErrorMessage ?? audio.playbackErrorMessage ?? store.status)
                            .font(.footnote)
                            .foregroundColor(
                                audio.recordingErrorMessage == nil && audio.playbackErrorMessage == nil
                                    ? .secondary : .red
                            )
                            .frame(minHeight: 22)
                        Button {
                            startSubmitCommand()
                        } label: {
                            HStack(spacing: 10) {
                                if store.isAskingKibo {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(store.isAskingKibo ? "Asking Kibo…" : "Ask Kibo")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            store.selectedConversationID == nil || store.recoveryItemCount > 0
                        )
                        .padding(.horizontal)
                    }
                    .padding(.top, 22)

                    Spacer(minLength: 12)

                    talkButton(diameter: buttonDiameter)
                        .padding(.bottom, 84)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onAppear { replyLifecycle.appear(isActive: scenePhase == .active) }
        .task { await audio.prepare() }
        .onChange(of: store.events) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: audio.loadingID) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: audio.playingID) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: audio.lastFinishedID) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: audio.isHolding) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: audio.automaticPlaybackSuspended) { _, suspended in
            if suspended { replyLifecycle.suspendPlayback() }
            else { playAwaitedReplyIfReady() }
        }
        .onChange(of: showingSettings) { _, presented in
            if !presented { playAwaitedReplyIfReady() }
        }
        .onChange(of: replyDestination) { _, _ in
            // Invalidate every UI-owned completion before stop notifications
            // can cause another autoplay evaluation.
            replyLifecycle.selectionChanged()
            cancelReplyCommand()
            audio.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                replyLifecycle.becomeInactive()
                cancelReplyCommand()
                audio.stopForInactivity()
            } else {
                replyLifecycle.becomeActive()
                Task { await audio.prepare() }
                playAwaitedReplyIfReady()
            }
        }
        .onDisappear {
            replyLifecycle.disappear()
            cancelReplyCommand()
            audio.stop()
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(store.projects) { project in
                    Button(project.name) { Task { await store.selectProject(project.id) } }
                }
            } label: {
                Label(store.selectedProject?.name ?? "Project", systemImage: "folder")
                    .lineLimit(1)
            }
            .disabled(audio.isRecording || audio.isStarting)
            Divider().frame(height: 22)
            Menu {
                ForEach(store.conversations) { conversation in
                    Button(conversation.name) { Task { await store.selectConversation(conversation.id) } }
                }
            } label: {
                Label(store.selectedConversation?.name ?? "Conversation", systemImage: "bubble.left")
                    .lineLimit(1)
            }
            .disabled(audio.isRecording || audio.isStarting)
            Spacer()
            Circle().fill(store.status == "Live" ? .green : .orange).frame(width: 8, height: 8)
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Settings")
        }
        .font(.subheadline.weight(.medium))
        .padding()
        .background(.background)
    }

    private func talkButton(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.kiboCoral.opacity(audio.isRecording ? 0.18 : 0.10))
                .frame(width: diameter, height: diameter)
                .scaleEffect(audio.isRecording ? 1 + audio.level * 0.12 : 1)
                .animation(.easeOut(duration: 0.08), value: audio.level)
            ZStack {
                Circle()
                    .fill(audio.isRecording ? Color.red : Color.kiboCoral)
                    .frame(width: diameter * 0.745, height: diameter * 0.745)
                    .shadow(color: .kiboCoral.opacity(0.35), radius: 24, y: 10)
                Image(systemName: audio.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(recordingPulse ? 1.07 : 1.0)
        }
        .onChange(of: audio.isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    recordingPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    recordingPulse = false
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(audio.isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if audio.isHolding { endHold() } else { beginHold() }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHold() }
            .onEnded { _ in endHold() }
        )
        .allowsHitTesting(store.selectedConversationID != nil)
    }

    private func playAwaitedReplyIfReady() {
        let gate = ReplyAutoplayGate(
            sceneIsActive: scenePhase == .active && replyLifecycle.allowsPlayback,
            systemPlaybackSuspended: audio.automaticPlaybackSuspended,
            captureIsActive: audio.isHolding || audio.isRecording || audio.isStarting,
            overlayIsPresented: showingSettings
        )
        guard gate.allowsPlayback else { return }
        guard let turnID = replyLifecycle.awaitedTurnID,
              let destination = replyLifecycle.awaitedDestination,
              destination == replyDestination else { return }
        switch store.events.replyAutoPlayAction(
            for: turnID,
            attemptedSpeechEventSeq: replyLifecycle.attemptedSpeechEventSeq,
            loadingID: audio.loadingID,
            playingID: audio.playingID,
            lastFinishedID: audio.lastFinishedID
        ) {
        case let .startPlayback(speechEventSeq):
            replyLifecycle.markPlaybackAttempt(speechEventSeq: speechEventSeq)
            audio.playReply(turnID: turnID, destination: destination, store: store)
        case .complete:
            replyLifecycle.clearPlayback()
        case .failed:
            let playbackID = "reply-\(turnID)"
            replyLifecycle.clearPlayback()
            if audio.loadingID == playbackID || audio.playingID == playbackID {
                audio.stopReply()
            }
        case .wait:
            break
        }
    }

    private var replyDestination: KiboDestination? { store.requestDestination }

    private func startSubmitCommand() {
        // Guard here instead of .disabled so the button doesn't flash
        // bright/gray on every push-to-talk cycle.
        guard !audio.isRecording, !audio.isStarting,
              !store.isUploading, !store.isAskingKibo,
              let destination = replyDestination else { return }
        replyCommandTask?.cancel()
        guard let claim = replyLifecycle.beginCommand(destination: destination) else { return }
        replyLifecycle.clearPlayback()
        audio.resumeAutomaticPlayback()
        replyCommandTask = Task {
            guard !Task.isCancelled,
                  replyLifecycle.accepts(claim, destination: replyDestination) else { return }
            let turnID = await store.submitTurn()
            guard !Task.isCancelled,
                  replyLifecycle.accepts(claim, destination: replyDestination) else { return }
            replyCommandTask = nil
            guard let turnID else { return }
            replyLifecycle.awaitReply(to: turnID, destination: claim.destination)
            playAwaitedReplyIfReady()
        }
    }

    private func cancelReplyCommand() {
        replyCommandTask?.cancel()
        replyCommandTask = nil
    }

    private func beginHold() {
        audio.beginHold()
    }

    private func endHold() {
        if let recording = audio.endHold() {
            store.queueRecording(recording)
        }
        playAwaitedReplyIfReady()
    }

}
