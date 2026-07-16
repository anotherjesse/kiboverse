import SwiftUI

struct TalkView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @State private var autoPlayTurnID: String?
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
                            // Guard here instead of .disabled so the button doesn't
                            // flash bright/gray on every push-to-talk cycle.
                            guard !audio.isRecording, !audio.isStarting,
                                  !store.isUploading, !store.isAskingKibo else { return }
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
        .task { await audio.prepare() }
        .onChange(of: store.events) { _, _ in playAwaitedReplyIfReady() }
        .onChange(of: store.selectedConversationID) { _, _ in
            autoPlayTurnID = nil
            audio.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                audio.stopForInactivity()
                cancelHold()
            } else {
                Task { await audio.prepare() }
            }
        }
        .onDisappear {
            audio.stop()
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
        guard let turnID = autoPlayTurnID else { return }
        if store.timeline.contains(where: { $0.turnID == turnID && $0.canPlay }) {
            autoPlayTurnID = nil
            audio.playReply(turnID: turnID, store: store)
        } else if store.events.contains(where: {
            ($0.kind == "reply_error" || $0.kind == "tts_error") && $0.turn == turnID
        }) {
            autoPlayTurnID = nil
        }
    }

    private func beginHold() {
        audio.beginHold()
    }

    private func endHold() {
        if let recording = audio.endHold() {
            store.queueRecording(recording)
        }
    }

    private func cancelHold() {
        audio.cancelHold()
    }
}
