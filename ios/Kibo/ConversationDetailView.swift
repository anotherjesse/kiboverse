import SwiftUI
import UIKit

struct ConversationDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @EnvironmentObject private var router: KiboRouter
    @StateObject private var session = ReplySession()
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    /// Fed by the shared gesture's `.armedChanged`; drives the excited face,
    /// the "Release to ask" copy, and the armed haptic.
    @State private var swipeArmed = false

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
        // The composer mic sits near the bottom edge; without this the home
        // indicator claims the swipe-up-to-ask gesture.
        .defersSystemGestures(on: .bottom)
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
        .sheet(isPresented: $isPhotoLibraryPresented) {
            PhotoLibraryPicker {
                // One batch-level gate, registered before the picker
                // dismisses: destination and intake timestamp are captured
                // once for the whole selection, so a mid-batch Ask or
                // navigation cannot split or redirect it.
                store.beginImageIntake(source: "library")
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCapture { payload in
                store.queueImage(data: payload, source: "camera")
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 16) {
            creature
            Spacer()
            composerStatus
            attachButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// The inline creature: Kibo's face on a `kiboInk` disc (the white sprite
    /// needs dark backing over the light material) wrapped by the shared
    /// `KiboStateRing`. The disc and gesture footprint stay 60pt — the old mic
    /// size — while the ring rides just outside it. Same shared hold-to-talk
    /// semantics the watch and talk mode use; the armed state (feeding the hint
    /// and haptic) and the askable guard stay here.
    private var creature: some View {
        let state = centerState
        let isEnabled = store.selectedConversationID != nil
        return ZStack {
            KiboStateRing(state: state, level: audio.level, diameter: 60, pacing: .phone)
                .frame(width: 80, height: 80)
            Circle()
                .fill(Color.kiboInk)
                .frame(width: 60, height: 60)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
            KiboFace(state: state, level: audio.level, diameter: 60)
        }
        // Keep the layout footprint at the old 60pt disc; the ring overflows
        // visually into the composer's vertical padding without clipping.
        .frame(width: 60, height: 60)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Circle())
        .overlay(alignment: .top) { swipeHint }
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeArmed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(audio.isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if audio.isHolding { session.endHold() } else { session.beginHold() }
        }
        // With no separate Ask button, the swipe gesture needs an
        // accessibility equivalent.
        .accessibilityAction(named: "Ask Kibo") { askKibo() }
        .holdToTalkGesture(swipeThreshold: 55) { event in
            switch event {
            case .began:
                session.beginHold()
            case let .armedChanged(armed):
                swipeArmed = armed
            case .canceled:
                session.cancelHold()
            case .saved:
                session.endHold()
            case .askRequested:
                askKibo()
            }
        }
        .allowsHitTesting(isEnabled)
        .accessibilityIdentifier("talk-button")
    }

    /// Transient, hold-only affordance for the release gesture — appears while
    /// the finger is down and highlights once the swipe is armed.
    @ViewBuilder
    private var swipeHint: some View {
        if audio.isHolding || audio.isRecording {
            HStack(spacing: 5) {
                Image(systemName: swipeArmed ? "sparkles" : "chevron.up")
                Text(swipeArmed ? "Release to ask" : "Swipe up to ask")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(swipeArmed ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                swipeArmed ? AnyShapeStyle(Color.kiboCoral) : AnyShapeStyle(.thinMaterial),
                in: Capsule()
            )
            .offset(y: -(60 * 0.24 + 44))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: swipeArmed)
            .transition(.opacity)
        }
    }

    /// The one phone-composer derivation of "what is Kibo doing right now" —
    /// drives the face sprite, the state ring, and the status label.
    private var centerState: CenterState {
        CenterState.derive(store: store, audio: audio, session: session, swipeArmed: swipeArmed)
    }

    /// The askable guard lives here — the release just ended (or discarded) the
    /// hold by our own hand, so `startSubmit` skips the capture-state guards
    /// whose published values may not have settled this tick.
    private func askKibo() {
        if store.askableItemCount > 0 {
            session.startSubmit(afterCaptureEnded: true)
        }
    }

    /// True when the visible `.error` is the playback error the "Audio
    /// unavailable" alert already presents (mirrors that alert's binding
    /// source). Recording/store errors have no alert on this screen, so the
    /// status slot must render them instead of leaving a confused face with no
    /// message.
    private var alertPresentsError: Bool {
        audio.recordingErrorMessage == nil
            && audio.playbackErrorMessage != nil
            && !router.isTalkModePresented
    }

    /// Swipe up on the face is the ask gesture; this replaces the old Ask
    /// button with passive feedback — what a swipe would submit, or the ask in
    /// flight — via the shared `StatusLabel`. The recovery button survives as
    /// its own actionable affordance.
    @ViewBuilder
    private var composerStatus: some View {
        if store.recoveryItemCount > 0 {
            // Recovery blocks every ask; surface the way out where the ask
            // gesture lives instead of leaving swipes silently ignored.
            Button {
                router.isSettingsPresented = true
            } label: {
                Label("Recovery needed", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
            }
        } else if !(centerState.isError && alertPresentsError) {
            // Exactly one error surface per screen: the "Audio unavailable"
            // alert owns playback errors (with modal dismissal), so the status
            // slot stays silent only for those. Recording and store errors have
            // no alert here, so they render in the shared StatusLabel as talk
            // mode does — never a confused face with zero message.
            StatusLabel(
                state: centerState,
                style: .adaptive,
                font: .subheadline.weight(.medium),
                kerning: 0
            )
        }
    }

    /// One attach entry point; intake goes straight to the pending sweep (no
    /// staging UI) — an added image normalizes, spools, uploads, and shows up
    /// as a "not asked yet" card for the next swipe-up ask to claim.
    private var attachButton: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") {
                isPhotoLibraryPresented = true
            }
            if CameraCapture.isAvailable {
                Button("Take Photo", systemImage: "camera") {
                    isCameraPresented = true
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.kiboCoral)
                .frame(width: 44, height: 44)
                .background(Color.kiboCoral.opacity(0.12), in: Circle())
        }
        .disabled(store.selectedConversationID == nil)
        .accessibilityLabel("Add photo")
        .accessibilityIdentifier("attach-button")
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
                    if let imageID = item.imageID, let sha256 = item.imageSHA256 {
                        TimelineImageView(
                            imageID: imageID,
                            sha256: sha256,
                            aspectRatio: item.imageAspectRatio
                        )
                    }
                    if item.imageID == nil || !item.body.isEmpty {
                        Text(item.body).textSelection(.enabled)
                    }
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
        if let clipID = item.clipID { return PlaybackID.clip(clipID) }
        if item.canPlay, let turnID = item.turnID { return PlaybackID.reply(turnID) }
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

/// Photo inside a timeline card, loaded through the sha256-verified cache.
/// Un-uploaded images never reach the timeline (pending count only), so this
/// view always has a durable server event behind it.
private struct TimelineImageView: View {
    @EnvironmentObject private var store: AppStore
    let imageID: String
    let sha256: String
    let aspectRatio: Double?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.kiboCoral.opacity(0.08))
                    .aspectRatio(aspectRatio ?? 4 / 3, contentMode: .fit)
                    .overlay {
                        if failed {
                            Label("Tap to retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .frame(maxWidth: 240, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            guard failed else { return }
            failed = false
            Task { await load() }
        }
        .task(id: sha256) { await load() }
        .accessibilityLabel("Photo")
        .accessibilityIdentifier("timeline-image")
    }

    private func load() async {
        guard image == nil else { return }
        if let loaded = await store.image(imageID: imageID, sha256: sha256) {
            image = loaded
        } else {
            failed = true
        }
    }
}
