import SwiftUI
import WatchKit

struct WatchTalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchStore()
    @StateObject private var audio = WatchAudioCoordinator()
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
                audio.prepare()
            }
            .onChange(of: store.events) { _, _ in playAwaitedReplyIfReady() }
            .onChange(of: store.selectedConversationID) { _, _ in
                awaitedTurnID = nil
                audio.conversationChanged()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    audio.stopForInactivity()
                } else {
                    audio.prepare()
                }
            }
            .onDisappear { audio.cancelHold() }
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
        if store.pendingUploadCount > 0 { return "Saved · tap Ask to retry" }
        return "Hold while you speak"
    }

    private func askKibo() {
        guard !audio.isRecording, !audio.isStarting else { return }
        audio.stopReply()
        Task {
            if let turnID = await store.submitTurn() {
                awaitedTurnID = turnID
                playAwaitedReplyIfReady()
            }
        }
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
        guard let turnID = awaitedTurnID else { return }
        if store.events.contains(where: {
            ($0.kind == "speech_ready" || ($0.kind == "reply" && $0.audio != nil))
                && $0.turn == turnID
        }) {
            awaitedTurnID = nil
            audio.playReply(turnID: turnID, store: store)
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
