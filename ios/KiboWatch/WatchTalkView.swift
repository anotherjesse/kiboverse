import SwiftUI
import WatchKit

struct WatchTalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: WatchStore
    @StateObject private var audio: WatchAudioCoordinator
    @State private var replyPlaybackIntent = ReplyPlaybackIntent()
    @State private var replyCommandScope = ReplyCommandScope()
    @State private var replyCommandTask: Task<Void, Never>?
    @State private var showingServer = false
    @State private var swipeArmed = false

    /// Swiping up past this arms release-to-ask.
    private static let swipeThreshold: CGFloat = 30

    init() {
        let store = WatchStore()
        _store = StateObject(wrappedValue: store)
        _audio = StateObject(wrappedValue: WatchAudioCoordinator(
            recordingInventoryDidChange: { [weak store] in
                store?.refreshRecordingInventory()
            }
        ))
    }

    var body: some View {
        NavigationStack {
            mainContent
            .toolbar {
                // Both are secondary actions: muted translucent discs, not
                // coral — the mic and Ask own the accent color.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Server", systemImage: "gearshape") { showingServer = true }
                        .labelStyle(.iconOnly)
                        .tint(Color.white.opacity(0.15))
                        .foregroundStyle(.white.opacity(0.85))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSelectionView(store: store)
                    } label: {
                        Label("Choose conversation", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .tint(Color.white.opacity(0.15))
                    .foregroundStyle(.white.opacity(0.85))
                    .disabled(audio.isRecording || audio.isStarting)
                    .accessibilityIdentifier("watch-choose-button")
                }
            }
            .sheet(isPresented: $showingServer) { WatchServerView(store: store) }
            .onAppear {
                replyCommandScope.appear(isActive: scenePhase == .active)
                store.setSceneActive(scenePhase == .active)
            }
            .task {
                await store.start()
                guard !Task.isCancelled, replyCommandScope.allowsPlayback else { return }
                audio.prepare()
            }
            .onChange(of: store.eventRevision) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: audio.loadingID) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: audio.playingID) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: audio.lastFinishedID) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: audio.automaticPlaybackSuspended) { _, suspended in
                if suspended {
                    replyPlaybackIntent.suspendPlayback()
                } else {
                    playAwaitedReplyIfReady()
                }
            }
            .onChange(of: store.selectedConversationID) { _, _ in
                replyCommandScope.selectionChanged()
                cancelReplyCommand()
                replyPlaybackIntent.clear()
                audio.conversationChanged()
            }
            .onChange(of: scenePhase) { _, phase in
                store.setSceneActive(phase == .active)
                replyCommandScope.setActive(phase == .active)
                if phase != .active {
                    cancelReplyCommand()
                    replyPlaybackIntent.suspendPlayback()
                    audio.stopForInactivity()
                } else {
                    audio.prepare()
                    playAwaitedReplyIfReady()
                }
            }
            .onDisappear {
                replyCommandScope.disappear()
                cancelReplyCommand()
                replyPlaybackIntent.clear()
                audio.stopForInactivity()
            }
        }
    }

    /// The single state the status line, face expression, and constellation
    /// animation all render.
    private var centerState: CenterState {
        .derive(
            hasConversation: store.selectedConversationID != nil,
            swipeArmed: swipeArmed,
            isStarting: audio.isStarting,
            isRecording: audio.isRecording,
            errorMessage: errorText,
            isSending: store.isUploading,
            isThinking: store.isAskingKibo,
            isLoadingReply: audio.loadingID != nil,
            isSpeaking: audio.playingID != nil,
            didFinishReply: replyPlaybackIntent.finishedTurnID != nil,
            recoveryItemCount: store.recoveryItemCount,
            hasRetryableFailure: store.events.retryableFailure != nil,
            pendingCount: askableClipCount,
            savedCount: store.pendingUploadCount
        )
    }

    /// Non-scrolling main screen: the conversation constellation fills the
    /// display with Kibo's face dead center (the Canvas and the face must
    /// share a center for the ring/tick geometry to line up), destination at
    /// the top, compact Retry/Review + one-line status at the bottom.
    private var mainContent: some View {
        ZStack {
            // Face and Canvas share one coordinate space (and one offset):
            // the ring/tick geometry is drawn around the Canvas center.
            ZStack {
                ConstellationView(
                    markers: store.constellationMarkers,
                    state: centerState,
                    level: audio.level,
                    faceDiameter: micDiameter,
                    style: .watch
                )
                talkButton
            }
            .offset(y: 10)
            .ignoresSafeArea()
            VStack(spacing: 2) {
                conversationHeader
                Spacer(minLength: 2)
                bottomRow
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Display-only destination label; switching lives behind the folder
    /// button in the toolbar. Serif echoes the Kibo wordmark in the concept
    /// art; dimmed so the constellation stays the subject.
    private var conversationHeader: some View {
        Text(selectedConversationName)
            .font(.system(size: 12, weight: .semibold, design: .serif).smallCaps())
            .kerning(1.1)
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    /// Swipe up on the mic is the ask gesture, so no Ask button — the slot
    /// holds Retry when recovery is possible, a Review shortcut when saved
    /// recordings are blocking asks, otherwise just the status line.
    private var bottomRow: some View {
        // Caption above, pill below: the button hugs the screen's bottom
        // edge instead of clipping the bunny's chin.
        VStack(spacing: 2) {
            statusLabel
            // Driven off the rendered `centerState`, not raw store fields —
            // needsReview outranks attention exactly as the CenterState
            // priority chain already encodes, and both stay hidden during
            // every live/error state.
            if centerState == .needsReview {
                reviewButton
            } else if centerState == .attention, let target = store.events.retryableFailure {
                retryButton(target)
            }
        }
    }

    /// Recovery items block every ask until they are reviewed; give that
    /// state a direct way out instead of a truncated instruction.
    private var reviewButton: some View {
        CoralActionPill(title: "Review saved", systemImage: "exclamationmark.arrow.circlepath") {
            showingServer = true
        }
        .controlSize(.mini)
        .accessibilityIdentifier("watch-review-button")
    }

    private var statusLabel: some View {
        StatusLabel(
            state: centerState,
            style: .onDark,
            font: .system(size: 13, weight: .medium),
            kerning: 0.6
        )
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: 14)
        .accessibilityIdentifier("watch-status")
    }

    private func retryButton(_ target: RetryTarget) -> some View {
        CoralActionPill(
            title: "Retry",
            systemImage: "arrow.clockwise",
            isBusy: store.isRetryingFailedWork
        ) {
            retryFailedWork(target)
        }
        .controlSize(.mini)
        .disabled(store.isRetryingFailedWork)
        .accessibilityIdentifier("watch-retry-button")
    }

    /// Media the next "Ask" would submit: unclaimed clips AND images on the
    /// server plus any clips queued on this watch for the SELECTED
    /// conversation — spooled clips for other conversations and recovery
    /// items never count. Images count because a turn claims them too; the
    /// status line must agree with the constellation's bright markers.
    private var askableClipCount: Int {
        store.events.unclaimedMediaCount + store.localAskableClipCount
    }

    private var selectedConversationName: String {
        store.selectedConversation?.name ?? "Choose conversation"
    }

    /// Face diameter: still the dominant press target, but sized to leave
    /// the constellation a legible orbit band around it.
    private var micDiameter: CGFloat {
        WKInterfaceDevice.current().screenBounds.width * 0.48
    }

    private var talkButton: some View {
        // Sprite, inset, and recording pulse all live in the shared
        // `KiboFace` now — same organism the phone uses.
        KiboFace(state: centerState, level: audio.level, diameter: micDiameter)
            .opacity(store.selectedConversationID != nil ? 1 : 0.4)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("watch-talk-button")
            .accessibilityLabel("Hold to talk")
            .accessibilityValue(audio.isRecording ? "Recording" : "Ready")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if audio.isHolding { endHold() } else { beginHold() }
            }
            // With no separate Ask button, the swipe gesture needs an
            // accessibility equivalent.
            .accessibilityAction(named: "Ask Kibo") { askKibo() }
            // Shared hold-to-talk semantics; watch haptics and the askable-count
            // guard stay here — the release just ended by our own hand, so the ask
            // path skips the capture-state guards whose published values may not
            // have settled on this exact tick.
            .holdToTalkGesture(swipeThreshold: Self.swipeThreshold) { event in
                switch event {
                case .began:
                    beginHold()
                case let .armedChanged(armed):
                    swipeArmed = armed
                    if armed { WKInterfaceDevice.current().play(.directionUp) }
                case .canceled:
                    audio.cancelHold()
                case .saved:
                    endHold()
                case .askRequested:
                    if askableClipCount > 0 {
                        performAsk()
                    } else {
                        WKInterfaceDevice.current().play(.failure)
                    }
                }
            }
            .allowsHitTesting(store.selectedConversationID != nil)
    }

    private var errorText: String? {
        audio.recordingErrorMessage ?? audio.playbackErrorMessage ?? store.errorMessage
    }

    private func askKibo() {
        guard !audio.isRecording, !audio.isStarting else { return }
        performAsk()
    }

    private func performAsk() {
        guard let claim = replyCommandScope.beginCommand(
                destination: store.requestDestination
              ) else { return }
        replyCommandTask?.cancel()
        replyPlaybackIntent.clear()
        audio.stopReply()
        audio.resumeAutomaticPlayback()
        replyCommandTask = Task {
            guard !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    destination: store.requestDestination
                  ) else { return }
            guard let turnID = await store.submitTurn(
                serverURL: claim.destination.serverURL,
                projectID: claim.destination.projectID,
                conversationID: claim.destination.conversationID
            ), !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    destination: store.requestDestination
                  ) else { return }
            replyPlaybackIntent.awaitReply(to: turnID, destination: claim.destination)
            playAwaitedReplyIfReady()
        }
    }

    private func retryFailedWork(_ target: RetryTarget) {
        guard let claim = replyCommandScope.beginCommand(
            destination: store.requestDestination
        ) else { return }
        replyCommandTask?.cancel()
        replyPlaybackIntent.clear()
        audio.stopReply()
        audio.resumeAutomaticPlayback()
        replyCommandTask = Task {
            guard !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    destination: store.requestDestination
                  ) else { return }
            let outcome = await store.retryFailedWork(
                target,
                serverURL: claim.destination.serverURL,
                projectID: claim.destination.projectID,
                conversationID: claim.destination.conversationID
            )
            guard !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    destination: store.requestDestination
                  ) else { return }
            replyPlaybackIntent.retryFinished(
                target,
                outcome: outcome,
                destination: claim.destination
            )
            playAwaitedReplyIfReady()
        }
    }

    private func cancelReplyCommand() {
        replyCommandTask?.cancel()
        replyCommandTask = nil
    }

    private func beginHold() {
        guard !audio.isHolding, store.selectedConversationID != nil else { return }
        WKInterfaceDevice.current().play(.start)
        audio.beginHold()
    }

    private func endHold() {
        guard audio.isHolding else { return }
        if let recording = audio.endHold() {
            WKInterfaceDevice.current().play(.stop)
            store.queueRecording(recording)
        }
    }

    private func playAwaitedReplyIfReady() {
        guard replyCommandScope.allowsPlayback,
              !audio.automaticPlaybackSuspended,
              let destination = replyPlaybackIntent.awaitedDestination,
              destination == store.requestDestination else { return }
        switch replyPlaybackIntent.advance(
            events: store.events,
            eventsRevision: store.eventRevision,
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
}

struct WatchSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WatchStore

    var body: some View {
        // The trigger on the main screen shows the conversation name, so the
        // conversation picker leads; switching projects is the rarer action
        // and lives below.
        List {
            if !store.conversations.isEmpty {
                Section("Conversation") {
                    ForEach(store.conversations) { conversation in
                        Button {
                            Task {
                                await store.selectConversation(conversation.id)
                                dismiss()
                            }
                        } label: {
                            Label(
                                conversation.name,
                                systemImage: conversation.id == store.selectedConversationID
                                    ? "checkmark.circle.fill" : "bubble.left"
                            )
                        }
                    }
                }
            }
            Section("Project") {
                ForEach(store.projects) { project in
                    Button {
                        Task { await store.selectProject(project.id) }
                    } label: {
                        Label(
                            project.name,
                            systemImage: project.id == store.selectedProjectID
                                ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        }
        .navigationTitle("Choose")
    }
}

struct WatchServerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WatchStore
    @State private var value = ""
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $value)
                    .textInputAutocapitalization(.never)
                Button("Connect") {
                    Task { if await store.saveServer(value) { dismiss() } }
                }
                if store.pendingUploadCount > 0 {
                    Section("Saved recordings") {
                        Text("\(store.pendingUploadCount) saved")
                        if store.recoveryItemCount > 0 {
                            Text("\(store.recoveryItemCount) need review")
                        }
                        Button("Discard", role: .destructive) {
                            confirmingDiscard = true
                        }
                        .disabled(store.isUploading)
                    }
                }
            }
            .navigationTitle("Server")
            .onAppear {
                value = store.serverURL
                store.refreshRecordingInventory()
            }
            .alert("Discard recordings?", isPresented: $confirmingDiscard) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) { store.discardPendingUploads() }
            } message: {
                Text("Recordings that have not reached the server will be permanently deleted.")
            }
        }
    }
}
