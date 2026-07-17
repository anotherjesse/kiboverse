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
    @State private var holdStartedAt: Date?
    @State private var swipeArmed = false

    /// Swiping up past this arms release-to-ask.
    private static let swipeThreshold: CGFloat = 30
    /// Sub-second releases never produce a recording: with a swipe they ask
    /// with what's already pending, without one the capture is silently
    /// discarded. Only holds of 1s+ are real recordings.
    private static let recordThreshold: TimeInterval = 1.0

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

    /// Non-scrolling main screen: destination at top, dominant mic in the
    /// center, compact Ask/Retry + one-line status at the bottom. Fits 42mm
    /// and 46mm faces without scrolling.
    private var mainContent: some View {
        VStack(spacing: 2) {
            conversationHeader
            Spacer(minLength: 2)
            talkButton
            Spacer(minLength: 2)
            bottomRow
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Display-only destination label; switching lives behind the folder
    /// button in the toolbar.
    private var conversationHeader: some View {
        Text(selectedConversationName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    /// Swipe up on the mic is the ask gesture, so no Ask button — the slot
    /// holds Retry when recovery is possible, a Review shortcut when saved
    /// recordings are blocking asks, otherwise just the status line.
    private var bottomRow: some View {
        VStack(spacing: 2) {
            if let target = store.events.retryableFailure {
                retryButton(target)
            } else if store.recoveryItemCount > 0 {
                reviewButton
            }
            statusLabel
        }
    }

    /// Recovery items block every ask until they are reviewed; give that
    /// state a direct way out instead of a truncated instruction.
    private var reviewButton: some View {
        Button {
            showingServer = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                Text("Review saved")
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.kiboCoral)
        .controlSize(.mini)
        .accessibilityIdentifier("watch-review-button")
    }

    private var statusLabel: some View {
        Text(statusText)
            .accessibilityIdentifier("watch-status")
            .font(.caption2)
            .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 14)
    }

    private func retryButton(_ target: RetryTarget) -> some View {
        Button {
            retryFailedWork(target)
        } label: {
            HStack(spacing: 4) {
                if store.isRetryingFailedWork {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("Retry")
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.kiboCoral)
        .controlSize(.mini)
        .disabled(store.isRetryingFailedWork)
        .accessibilityIdentifier("watch-retry-button")
    }

    /// Clips the next "Ask" would submit: unclaimed on the server plus any
    /// queued on this watch for the SELECTED conversation — clips spooled
    /// for other conversations and recovery items never count.
    private var askableClipCount: Int {
        store.events.unclaimedClipCount + store.localAskableClipCount
    }

    private var selectedConversationName: String {
        store.selectedConversation?.name ?? "Choose conversation"
    }

    /// Mic circle diameter sized to dominate the center on any watch face.
    private var micDiameter: CGFloat {
        WKInterfaceDevice.current().screenBounds.width * 0.55
    }

    private var talkButton: some View {
        ZStack {
            if audio.isRecording {
                WatchRecordingRing(diameter: micDiameter, delay: 0.0)
                WatchRecordingRing(diameter: micDiameter, delay: 0.45)
                WatchRecordingRing(diameter: micDiameter, delay: 0.9)
            }
            Circle()
                .fill(audio.isRecording ? Color.red : Color.kiboCoral)
                .frame(width: micDiameter, height: micDiameter)
                .shadow(
                    color: (audio.isRecording ? Color.red : Color.kiboCoral).opacity(0.35),
                    radius: micDiameter * 0.11,
                    y: micDiameter * 0.045
                )
                .scaleEffect(audio.isRecording ? 1 + audio.level * 0.12 : 1)
                .animation(.easeOut(duration: 0.08), value: audio.level)
            Image(systemName: micGlyph)
                .font(.system(size: micDiameter * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: micDiameter, height: micDiameter)
        .opacity(store.selectedConversationID != nil ? 1 : 0.4)
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
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if holdStartedAt == nil {
                        holdStartedAt = value.time
                        beginHold()
                    }
                    let armed = value.translation.height <= -Self.swipeThreshold
                    if armed != swipeArmed {
                        swipeArmed = armed
                        if armed { WKInterfaceDevice.current().play(.directionUp) }
                    }
                }
                .onEnded { value in
                    let startedAt = holdStartedAt
                    holdStartedAt = nil
                    swipeArmed = false
                    let heldFor = startedAt.map { value.time.timeIntervalSince($0) } ?? 0
                    let swiped = value.translation.height <= -Self.swipeThreshold
                    if heldFor < Self.recordThreshold {
                        audio.cancelHold()
                    } else {
                        endHold()
                    }
                    guard swiped else { return }
                    // The hold just ended by our own hand — skip the
                    // capture-state guards, whose published values may not
                    // have settled on this exact tick.
                    if askableClipCount > 0 {
                        performAsk()
                    } else {
                        WKInterfaceDevice.current().play(.failure)
                    }
                }
        )
        .allowsHitTesting(store.selectedConversationID != nil)
    }

    private var micGlyph: String {
        if swipeArmed { return "sparkles" }
        return audio.isRecording ? "waveform" : "mic.fill"
    }

    private var errorText: String? {
        audio.recordingErrorMessage ?? audio.playbackErrorMessage ?? store.errorMessage
    }

    /// Dynamic states only — no persistent instructional copy.
    private var statusText: String {
        if let errorText { return errorText }
        if swipeArmed { return "Release to ask" }
        if audio.isStarting { return "Opening microphone…" }
        if audio.isRecording { return "Listening…" }
        if store.isUploading { return "Sending…" }
        if store.isAskingKibo { return "Kibo is thinking…" }
        if audio.loadingID != nil { return "Loading reply…" }
        if audio.playingID != nil { return "Kibo is speaking" }
        if audio.lastFinishedID != nil { return "Reply played" }
        if store.recoveryItemCount > 0 { return "Recording needs review" }
        if askableClipCount > 0 { return "\(askableClipCount) pending" }
        if store.pendingUploadCount > 0 { return "Saved on watch" }
        return ""
    }

    private func askKibo() {
        guard !audio.isRecording, !audio.isStarting else { return }
        performAsk()
    }

    private func performAsk() {
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

/// One expanding, fading ring of the recording pulse — the same treatment as
/// iOS's MicButton: red fill + staggered rings means a single static frame
/// mid-recording still reads as "recording".
private struct WatchRecordingRing: View {
    let diameter: CGFloat
    let delay: Double
    @State private var expanded = false
    @State private var faded = false

    var body: some View {
        // Rings start at 1.15x so a fresh ring immediately clears the fill
        // (which grows to 1.12x with level), and opacity fades linearly
        // while scale eases out — a static frame at any phase shows 2–3
        // visible staggered rings.
        Circle()
            .stroke(Color.red.opacity(faded ? 0 : 0.6), lineWidth: 3)
            .frame(width: diameter, height: diameter)
            .scaleEffect(expanded ? 1.8 : 1.15)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.35)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    expanded = true
                }
                withAnimation(
                    .linear(duration: 1.35)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    faded = true
                }
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
