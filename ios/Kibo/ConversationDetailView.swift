import SwiftUI

struct ConversationDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @EnvironmentObject private var router: KiboRouter
    @StateObject private var session = ReplySession()

    var body: some View {
        Group {
            if store.selectedConversation == nil {
                ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        let items = store.timeline
                        LazyVStack(spacing: 4) {
                            if items.isEmpty {
                                ContentUnavailableView(
                                    "No conversation yet", systemImage: "waveform",
                                    description: Text("Hold the mic to record a thought, then ask Kibo.")
                                ).padding(.top, 80)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                MessageCard(
                                    item: item,
                                    isGroupStart: index == 0
                                        || items[index - 1].role != item.role
                                        || items[index - 1].title != item.title
                                )
                                .id(item.id)
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: store.timeline.count) { _, _ in
                        if let id = store.timeline.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                .safeAreaInset(edge: .bottom) { composer }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(store.selectedConversation?.name ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Expand arrows, not a waveform: this enters the immersive
                // full-screen talk mode (a waveform reads as playback or a
                // visualizer).
                Button("Talk mode", systemImage: "arrow.up.left.and.arrow.down.right") {
                    router.isTalkModePresented = true
                }
                .disabled(store.selectedConversationID == nil)
                .accessibilityIdentifier("talk-mode-button")
            }
        }
        .replySessionDriver(
            session,
            overlayIsPresented: router.isTalkModePresented || router.isSettingsPresented
        )
        // Talk mode surfaces playback errors in its own status line; a modal
        // here would re-show the same error, stale, after the cover closes.
        .alert("Audio unavailable", isPresented: Binding(
            get: { audio.playbackErrorMessage != nil && !router.isTalkModePresented },
            set: { if !$0 { audio.playbackErrorMessage = nil } }
        )) { Button("OK") { audio.playbackErrorMessage = nil } }
        message: { Text(audio.playbackErrorMessage ?? "Unknown playback error") }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 16) {
            MicButton(
                diameter: 60,
                isRecording: audio.isRecording,
                isHolding: audio.isHolding,
                level: audio.level,
                isEnabled: store.selectedConversationID != nil,
                beginHold: { session.beginHold() },
                endHold: { session.endHold() }
            )
            Spacer()
            AskKiboButton { session.startSubmit() }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    // MARK: - Timeline cards

    @ViewBuilder
    private func MessageCard(item: TimelineItem, isGroupStart: Bool) -> some View {
        let playbackID = playbackID(for: item)
        let isLoading = playbackID != nil && audio.loadingID == playbackID
        let isPlaying = playbackID != nil && audio.playingID == playbackID
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack {
            if item.role == .person { Spacer(minLength: 44) }
            VStack(alignment: item.role == .person ? .trailing : .leading, spacing: 4) {
                if isGroupStart {
                    Text(item.title)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.body).textSelection(.enabled)
                    if playbackID != nil {
                        HStack(spacing: 5) {
                            if isLoading {
                                ProgressView().controlSize(.mini)
                                Text("Loading…")
                            } else {
                                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                Text(isPlaying ? "Stop" : durationLabel(item))
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.role == .person ? Color.kiboCoral : .secondary)
                    }
                }
                .padding(14)
                .background(bubbleColor(for: item, active: isPlaying || isLoading))
                .clipShape(shape)
                .contentShape(shape)
                .onTapGesture { togglePlayback(item) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(playbackID == nil ? [] : .isButton)
                .accessibilityHint(playbackID == nil ? "" : "Double tap to play the audio")
                if let retryTarget = item.retryTarget {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await store.retryFailedWork(retryTarget) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isRetryingFailedWork)
                }
            }
            if item.role != .person { Spacer(minLength: 44) }
        }
        .padding(.top, isGroupStart ? 10 : 0)
    }

    private func playbackID(for item: TimelineItem) -> String? {
        if let clipID = item.clipID { return "clip-\(clipID)" }
        if item.canPlay, let turnID = item.turnID { return "reply-\(turnID)" }
        return nil
    }

    private func togglePlayback(_ item: TimelineItem) {
        if let clipID = item.clipID {
            audio.toggleClip(clipID: clipID, store: store)
        } else if item.canPlay,
                  let turnID = item.turnID,
                  let destination = store.requestDestination {
            audio.toggleReply(turnID: turnID, destination: destination, store: store)
        }
    }

    private func durationLabel(_ item: TimelineItem) -> String {
        guard let ms = item.durationMs else { return item.role == .kibo ? "Play reply" : "Play" }
        let seconds = max(1, Int((Double(ms) / 1000).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func bubbleColor(for item: TimelineItem, active: Bool) -> Color {
        if item.role == .person {
            return Color.kiboCoral.opacity(active ? 0.30 : 0.15)
        }
        return active ? Color.kiboCoral.opacity(0.12) : Color(.secondarySystemGroupedBackground)
    }
}
