import SwiftUI

struct ConversationDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var player: SpeechPlayer

    var body: some View {
        Group {
            if store.selectedConversation == nil {
                ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if store.timeline.isEmpty {
                                ContentUnavailableView(
                                    "No conversation yet", systemImage: "waveform",
                                    description: Text("Use Talk to record a thought, then ask Kibo.")
                                ).padding(.top, 80)
                            }
                            ForEach(store.timeline) { item in
                                MessageCard(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: store.timeline.count) { _, _ in
                        if let id = store.timeline.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                .safeAreaInset(edge: .bottom) { compactComposer }
            }
        }
        .navigationTitle(store.selectedConversation?.name ?? "Conversation")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Label(store.status, systemImage: store.status == "Live" ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Audio unavailable", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) { Button("OK") { player.errorMessage = nil } }
        message: { Text(player.errorMessage ?? "Unknown playback error") }
    }

    private var compactComposer: some View {
        HStack(spacing: 12) {
            NavigationLink {
                TalkView()
            } label: {
                Label("Talk", systemImage: "mic.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            Button("Ask Kibo", systemImage: "sparkles") { Task { await store.submitTurn() } }
                .buttonStyle(.bordered)
                .disabled(store.isUploading || store.isSubmitting)
        }
        .onChange(of: store.selectedConversationID) { _, _ in player.stop() }
        .onDisappear { player.stop() }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func MessageCard(item: TimelineItem) -> some View {
        HStack {
            if item.role == .person { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.body).textSelection(.enabled)
                ForEach(item.clipIDs, id: \.self) { clipID in
                    let playbackID = "clip-\(clipID)"
                    Button(player.playingID == playbackID ? "Stop recording" : "Play recording", systemImage: player.playingID == playbackID ? "stop.fill" : "waveform") {
                        player.toggleClip(clipID: clipID, store: store)
                    }
                    .buttonStyle(.bordered)
                }
                if item.canPlay, let turnID = item.turnID {
                    let playbackID = "reply-\(turnID)"
                    Button(player.playingID == playbackID ? "Stop" : "Play reply", systemImage: player.playingID == playbackID ? "stop.fill" : "play.fill") {
                        player.toggleReply(turnID: turnID, store: store)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(item.role == .person ? Color.kiboCoral.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if item.role != .person { Spacer(minLength: 44) }
        }
    }
}
