import SwiftUI
import WatchKit

struct WatchReplyPlaybackIntent: Equatable {
    private(set) var awaitedTurnID: String?
    private(set) var awaitedDestination: KiboDestination?
    private(set) var attemptedSpeechEventSeq: UInt64?
    private(set) var requiredEventsRevision: UInt64?

    mutating func awaitReply(to turnID: String, destination: KiboDestination) {
        awaitedTurnID = turnID
        awaitedDestination = destination
        attemptedSpeechEventSeq = nil
        requiredEventsRevision = nil
    }

    mutating func markPlaybackAttempt(speechEventSeq: UInt64) {
        attemptedSpeechEventSeq = speechEventSeq
    }

    mutating func suspendPlayback() {
        attemptedSpeechEventSeq = nil
    }

    mutating func clear() {
        awaitedTurnID = nil
        awaitedDestination = nil
        attemptedSpeechEventSeq = nil
        requiredEventsRevision = nil
    }

    mutating func retryFinished(
        _ target: RetryTarget,
        outcome: WatchRetryWorkOutcome,
        destination: KiboDestination
    ) {
        guard case let .accepted(requiredEventsRevision) = outcome,
              case let .turn(turnID) = target else { return }
        awaitReply(to: turnID, destination: destination)
        self.requiredEventsRevision = requiredEventsRevision
    }

    func canEvaluate(eventsRevision: UInt64) -> Bool {
        guard let requiredEventsRevision else { return true }
        return eventsRevision >= requiredEventsRevision
    }

    func autoPlayAction(
        events: [KiboEvent],
        eventsRevision: UInt64,
        loadingID: String?,
        playingID: String?,
        lastFinishedID: String?
    ) -> ReplyAutoPlayAction? {
        guard let awaitedTurnID, canEvaluate(eventsRevision: eventsRevision) else { return nil }
        return events.replyAutoPlayAction(
            for: awaitedTurnID,
            attemptedSpeechEventSeq: attemptedSpeechEventSeq,
            loadingID: loadingID,
            playingID: playingID,
            lastFinishedID: lastFinishedID
        )
    }
}

struct WatchReplyCommandClaim: Equatable {
    fileprivate let generation: UUID
    fileprivate let destination: KiboDestination
}

struct WatchReplyCommandScope: Equatable {
    private var generation = UUID()
    private(set) var isVisible = false
    private(set) var isActive = false

    var allowsPlayback: Bool { isVisible && isActive }

    mutating func appear(isActive: Bool) {
        generation = UUID()
        isVisible = true
        self.isActive = isActive
    }

    mutating func setActive(_ active: Bool) {
        if isActive && !active { generation = UUID() }
        isActive = active
    }

    mutating func selectionChanged() {
        generation = UUID()
    }

    mutating func disappear() {
        generation = UUID()
        isVisible = false
        isActive = false
    }

    mutating func beginCommand(
        serverURL: String,
        projectID: String?,
        conversationID: String?
    ) -> WatchReplyCommandClaim? {
        guard allowsPlayback, let projectID, let conversationID else { return nil }
        generation = UUID()
        return WatchReplyCommandClaim(
            generation: generation,
            destination: KiboDestination(
                serverURL: serverURL,
                projectID: projectID,
                conversationID: conversationID
            )
        )
    }

    func accepts(
        _ claim: WatchReplyCommandClaim,
        serverURL: String,
        projectID: String?,
        conversationID: String?
    ) -> Bool {
        guard allowsPlayback,
              claim.generation == generation,
              let projectID,
              let conversationID else { return false }
        return claim.destination == KiboDestination(
            serverURL: serverURL,
            projectID: projectID,
            conversationID: conversationID
        )
    }
}

struct WatchTalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: WatchStore
    @StateObject private var audio: WatchAudioCoordinator
    @State private var replyPlaybackIntent = WatchReplyPlaybackIntent()
    @State private var replyCommandScope = WatchReplyCommandScope()
    @State private var replyCommandTask: Task<Void, Never>?
    @State private var showingServer = false

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
            .navigationTitle("Kibo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Server", systemImage: "gearshape") { showingServer = true }
                        .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showingServer) { WatchServerView(store: store) }
            .onAppear {
                replyCommandScope.appear(isActive: scenePhase == .active)
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

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 7) {
                selectionLink
                talkButton
                statusLabel
                askButton
                retryButton
            }
            .padding(.horizontal, 5)
        }
    }

    private var selectionLink: some View {
        NavigationLink {
            WatchSelectionView(store: store)
        } label: {
            VStack(spacing: 1) {
                Text(selectedProjectName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(selectedConversationName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(audio.isRecording || audio.isStarting)
    }

    private var statusLabel: some View {
        Text(instructionText)
            .accessibilityIdentifier("watch-status")
            .font(.caption2)
            .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(minHeight: 24)
    }

    private var askButton: some View {
        Button(action: askKibo) {
            HStack(spacing: 5) {
                if store.isAskingKibo || store.isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(store.isAskingKibo ? "Thinking…" : "Ask Kibo")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(askDisabled)
        .accessibilityIdentifier("watch-ask-button")
    }

    @ViewBuilder
    private var retryButton: some View {
        if let target = store.events.retryableFailure {
            Button {
                retryFailedWork(target)
            } label: {
                if store.isRetryingFailedWork {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Retry failed work", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.isRetryingFailedWork)
            .accessibilityIdentifier("watch-retry-button")
        }
    }

    private var selectedProjectName: String {
        store.selectedProject?.name ?? "Choose project"
    }

    private var selectedConversationName: String {
        store.selectedConversation?.name ?? "Choose conversation"
    }

    private var askDisabled: Bool {
        store.selectedConversationID == nil
            || audio.isRecording
            || audio.isStarting
            || store.isSubmitting
            || store.recoveryItemCount > 0
    }

    private var talkButton: some View {
        ZStack {
            Circle()
                .fill(.orange.opacity(audio.isRecording ? 0.22 : 0.12))
                .frame(width: 104, height: 104)
                .scaleEffect(audio.isRecording ? 1 + audio.level * 0.12 : 1)
            Circle()
                .fill(audio.isRecording ? .red : .orange)
                .frame(width: 78, height: 78)
                .shadow(color: .orange.opacity(0.35), radius: 10, y: 4)
            Image(systemName: audio.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.08), value: audio.level)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("watch-talk-button")
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(audio.isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if audio.isHolding { endHold() } else { beginHold() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in endHold() }
        )
        .allowsHitTesting(store.selectedConversationID != nil)
    }

    private var errorText: String? {
        audio.recordingErrorMessage ?? audio.playbackErrorMessage ?? store.errorMessage
    }

    private var instructionText: String {
        if let errorText { return errorText }
        if audio.isStarting { return "Opening microphone…" }
        if audio.isRecording { return "Release to save" }
        if store.isUploading { return "Sending recording…" }
        if audio.loadingID != nil { return "Loading reply…" }
        if audio.playingID != nil { return "Kibo is speaking" }
        if audio.lastFinishedID != nil { return "Reply played" }
        if store.recoveryItemCount > 0 { return "Recovery needed · open Server" }
        if store.pendingUploadCount > 0 { return "Saved · tap Ask to retry" }
        return "Hold while you speak"
    }

    private func askKibo() {
        guard !audio.isRecording, !audio.isStarting,
              let claim = replyCommandScope.beginCommand(
                serverURL: store.serverURL,
                projectID: store.selectedProjectID,
                conversationID: store.selectedConversationID
              ) else { return }
        replyCommandTask?.cancel()
        replyPlaybackIntent.clear()
        audio.stopReply()
        audio.resumeAutomaticPlayback()
        replyCommandTask = Task {
            guard !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    serverURL: store.serverURL,
                    projectID: store.selectedProjectID,
                    conversationID: store.selectedConversationID
                  ) else { return }
            guard let turnID = await store.submitTurn(
                serverURL: claim.destination.serverURL,
                projectID: claim.destination.projectID,
                conversationID: claim.destination.conversationID
            ), !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    serverURL: store.serverURL,
                    projectID: store.selectedProjectID,
                    conversationID: store.selectedConversationID
                  ) else { return }
            replyPlaybackIntent.awaitReply(to: turnID, destination: claim.destination)
            playAwaitedReplyIfReady()
        }
    }

    private func retryFailedWork(_ target: RetryTarget) {
        guard let claim = replyCommandScope.beginCommand(
            serverURL: store.serverURL,
            projectID: store.selectedProjectID,
            conversationID: store.selectedConversationID
        ) else { return }
        replyCommandTask?.cancel()
        replyPlaybackIntent.clear()
        audio.stopReply()
        audio.resumeAutomaticPlayback()
        replyCommandTask = Task {
            guard !Task.isCancelled,
                  replyCommandScope.accepts(
                    claim,
                    serverURL: store.serverURL,
                    projectID: store.selectedProjectID,
                    conversationID: store.selectedConversationID
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
                    serverURL: store.serverURL,
                    projectID: store.selectedProjectID,
                    conversationID: store.selectedConversationID
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
              let turnID = replyPlaybackIntent.awaitedTurnID,
              let destination = replyPlaybackIntent.awaitedDestination,
              destination == store.requestDestination,
              let action = replyPlaybackIntent.autoPlayAction(
                events: store.events,
                eventsRevision: store.eventRevision,
                loadingID: audio.loadingID,
                playingID: audio.playingID,
                lastFinishedID: audio.lastFinishedID
              ) else { return }
        switch action {
        case let .startPlayback(speechEventSeq):
            replyPlaybackIntent.markPlaybackAttempt(speechEventSeq: speechEventSeq)
            audio.playReply(turnID: turnID, destination: destination, store: store)
        case .complete:
            replyPlaybackIntent.clear()
        case .failed:
            let playbackID = "reply-\(turnID)"
            replyPlaybackIntent.clear()
            if audio.loadingID == playbackID || audio.playingID == playbackID {
                audio.stopReply()
            }
        case .wait:
            break
        }
    }
}

struct WatchSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WatchStore

    var body: some View {
        List {
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
        }
        .navigationTitle("Talk to…")
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
