import SwiftUI
import WatchKit

struct WatchTalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchStore()
    @StateObject private var recorder = WatchAudioRecorder()
    @StateObject private var player = WatchSpeechPlayer()
    @State private var activeHoldID: UUID?
    @State private var recorderStartTask: Task<Void, Never>?
    @State private var awaitedTurnID: String?
    @State private var showingServer = false

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
            .task {
                await store.start()
                await recorder.prepare()
            }
            .onChange(of: store.events) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: store.selectedConversationID) { _, _ in
                awaitedTurnID = nil
                player.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    cancelHold()
                    player.stop()
                } else {
                    Task { await recorder.prepare() }
                }
            }
            .onDisappear { cancelHold() }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 7) {
                selectionLink
                talkButton
                statusLabel
                askButton
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
        .disabled(recorder.isRecording || recorder.isStarting)
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

    private var selectedProjectName: String {
        store.selectedProject?.name ?? "Choose project"
    }

    private var selectedConversationName: String {
        store.selectedConversation?.name ?? "Choose conversation"
    }

    private var askDisabled: Bool {
        store.selectedConversationID == nil
            || recorder.isRecording
            || recorder.isStarting
            || store.isSubmitting
    }

    private var talkButton: some View {
        ZStack {
            Circle()
                .fill(.orange.opacity(recorder.isRecording ? 0.22 : 0.12))
                .frame(width: 104, height: 104)
                .scaleEffect(recorder.isRecording ? 1 + recorder.level * 0.12 : 1)
            Circle()
                .fill(recorder.isRecording ? .red : .orange)
                .frame(width: 78, height: 78)
                .shadow(color: .orange.opacity(0.35), radius: 10, y: 4)
            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.08), value: recorder.level)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("watch-talk-button")
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(recorder.isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if activeHoldID == nil { beginHold() } else { endHold() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in endHold() }
        )
        .allowsHitTesting(store.selectedConversationID != nil)
    }

    private var errorText: String? {
        recorder.errorMessage ?? player.errorMessage ?? store.errorMessage
    }

    private var instructionText: String {
        if let errorText { return errorText }
        if recorder.isStarting { return "Opening microphone…" }
        if recorder.isRecording { return "Release to save" }
        if store.isUploading { return "Sending recording…" }
        if player.loadingID != nil { return "Loading reply…" }
        if player.playingID != nil { return "Kibo is speaking" }
        if player.lastFinishedID != nil { return "Reply played" }
        if store.pendingUploadCount > 0 { return "Saved · tap Ask to retry" }
        return "Hold while you speak"
    }

    private func askKibo() {
        guard !recorder.isRecording, !recorder.isStarting else { return }
        player.stop()
        Task {
            if let turnID = await store.submitTurn() {
                awaitedTurnID = turnID
                playAwaitedReplyIfReady()
            }
        }
    }

    private func beginHold() {
        guard activeHoldID == nil, store.selectedConversationID != nil else { return }
        let holdID = UUID()
        activeHoldID = holdID
        player.pauseForRecording()
        WKInterfaceDevice.current().play(.start)
        recorderStartTask = Task {
            let started = await recorder.start(holdID: holdID)
            guard !Task.isCancelled else {
                if started { recorder.cancel(holdID: holdID) }
                return
            }
            if !started, activeHoldID == holdID {
                player.resumeAfterRecording()
            }
            recorderStartTask = nil
        }
    }

    private func endHold() {
        guard let holdID = activeHoldID else { return }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        if let recording = recorder.stop(holdID: holdID) {
            WKInterfaceDevice.current().play(.stop)
            store.queueRecording(recording)
        }
        player.resumeAfterRecording()
    }

    private func cancelHold() {
        guard let holdID = activeHoldID else { return }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        recorder.cancel(holdID: holdID)
        player.resumeAfterRecording()
    }

    private func playAwaitedReplyIfReady() {
        guard let turnID = awaitedTurnID else { return }
        if store.events.contains(where: {
            ($0.kind == "speech_ready" || ($0.kind == "reply" && $0.audio != nil))
                && $0.turn == turnID
        }) {
            awaitedTurnID = nil
            player.playReply(turnID: turnID, store: store)
        } else if store.events.contains(where: {
            ($0.kind == "reply_error" || $0.kind == "tts_error") && $0.turn == turnID
        }) {
            awaitedTurnID = nil
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

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $value)
                    .textInputAutocapitalization(.never)
                Button("Connect") {
                    Task { if await store.saveServer(value) { dismiss() } }
                }
            }
            .navigationTitle("Server")
            .onAppear { value = store.serverURL }
        }
    }
}
