import SwiftUI

struct TalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var player: SpeechPlayer
    @State private var activeHoldID: UUID?
    @State private var recorderStartTask: Task<Void, Never>?
    @State private var autoPlayTurnID: String?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            selectionBar
            GeometryReader { geometry in
                let buttonDiameter = min(220.0, max(180.0, geometry.size.height * 0.34))
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Text(recorder.isRecording ? "Listening…" : "Push to talk")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(recorder.isRecording ? "Release when you’re finished" : "Hold the button while you speak")
                            .foregroundStyle(.secondary)
                        Text(recorder.errorMessage ?? player.errorMessage ?? store.status)
                            .font(.footnote)
                            .foregroundColor(
                                recorder.errorMessage == nil && player.errorMessage == nil
                                    ? .secondary : .red
                            )
                            .frame(minHeight: 22)
                        Button {
                            Task {
                                if let turnID = await store.submitTurn() {
                                    autoPlayTurnID = turnID
                                    playAwaitedReplyIfReady()
                                }
                            }
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
                        .disabled(store.selectedConversationID == nil || recorder.isRecording || recorder.isStarting || store.isUploading || store.isAskingKibo)
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
        .task { await recorder.prepare() }
        .onChange(of: store.events) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: store.selectedConversationID) { _, _ in
            autoPlayTurnID = nil
            player.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                player.stop()
                cancelHold()
            } else {
                Task { await recorder.prepare() }
            }
        }
        .onDisappear {
            player.stop()
            cancelHold()
            autoPlayTurnID = nil
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
            .disabled(recorder.isRecording || recorder.isStarting)
            Divider().frame(height: 22)
            Menu {
                ForEach(store.conversations) { conversation in
                    Button(conversation.name) { Task { await store.selectConversation(conversation.id) } }
                }
            } label: {
                Label(store.selectedConversation?.name ?? "Conversation", systemImage: "bubble.left")
                    .lineLimit(1)
            }
            .disabled(recorder.isRecording || recorder.isStarting)
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
                .fill(Color.kiboCoral.opacity(recorder.isRecording ? 0.18 : 0.10))
                .frame(width: diameter, height: diameter)
                .scaleEffect(recorder.isRecording ? 1 + recorder.level * 0.12 : 1)
                .animation(.easeOut(duration: 0.08), value: recorder.level)
            Circle()
                .fill(recorder.isRecording ? Color.red : Color.kiboCoral)
                .frame(width: diameter * 0.745, height: diameter * 0.745)
                .shadow(color: .kiboCoral.opacity(0.35), radius: 24, y: 10)
            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(recorder.isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if activeHoldID == nil { beginHold() } else { endHold() }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHold() }
            .onEnded { _ in endHold() }
        )
        .allowsHitTesting(store.selectedConversationID != nil)
    }

    private func playAwaitedReplyIfReady() {
        guard let turnID = autoPlayTurnID else { return }
        if store.timeline.contains(where: { $0.turnID == turnID && $0.canPlay }) {
            autoPlayTurnID = nil
            player.playReply(turnID: turnID, store: store)
        } else if store.events.contains(where: {
            ($0.kind == "reply_error" || $0.kind == "tts_error") && $0.turn == turnID
        }) {
            autoPlayTurnID = nil
        }
    }

    private func beginHold() {
        guard activeHoldID == nil else { return }
        let holdID = UUID()
        activeHoldID = holdID
        player.pauseForRecording()
        recorderStartTask = Task {
            guard !Task.isCancelled else { return }
            let started = await recorder.start(holdID: holdID)
            guard !Task.isCancelled else {
                if started { recorder.cancel(holdID: holdID) }
                return
            }
            if !started, activeHoldID == holdID {
                // Keep the gesture latched until release. DragGesture.onChanged
                // may fire repeatedly while the finger remains down; clearing the
                // ID here would start/pause/resume in a loop after a mic failure.
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
}
