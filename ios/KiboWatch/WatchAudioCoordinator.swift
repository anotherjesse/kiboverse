@preconcurrency import AVFoundation
import Combine
import Foundation

enum WatchAudioSessionIntent: Equatable {
    case prepareCapture
    case beginCapture
    case beginPlayback
    case rebuildPlayback
}

enum WatchAudioSystemEvent: Equatable {
    case outputRouteUnavailable
    case playbackConfigurationChanged
    case interruptionBegan
    case mediaServicesReset
}

@MainActor
protocol WatchAudioSessionControlling: AnyObject {
    func activate(for intent: WatchAudioSessionIntent) throws
    func deactivate()
}

@MainActor
final class WatchAudioSessionController: WatchAudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activate(for intent: WatchAudioSessionIntent) throws {
        if intent == .rebuildPlayback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        switch intent {
        case .prepareCapture, .beginCapture:
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetoothHFP]
            )
        case .beginPlayback, .rebuildPlayback:
            // Foreground short-form playback preserves the built-in Watch
            // speaker. Apple's long-form policy requires a Bluetooth route.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Sole UI-facing owner of Watch audio policy. Recorder, HTTP transport, PCM
/// state, and renderer remain independently replaceable mechanisms.
@MainActor
final class WatchAudioCoordinator: ObservableObject {
    private static let maximumReplySamples = 24_000 * 60 * 3

    private let recorder: any WatchAudioCapturing
    private let session: any WatchAudioSessionControlling
    private let player: PCMStreamingPlayer
    private let recordingInventoryDidChange: @MainActor () -> Void
    private var activeHoldID: UUID?
    private var recorderStartTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var routeRebuildTask: Task<Void, Never>?
    private var lifecycleEpoch = UUID()
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
    @Published private(set) var automaticPlaybackSuspended = false

    init(
        recorder: (any WatchAudioCapturing)? = nil,
        session: (any WatchAudioSessionControlling)? = nil,
        player: PCMStreamingPlayer? = nil,
        observeNotifications: Bool = true,
        recordingInventoryDidChange: @escaping @MainActor () -> Void = {}
    ) {
        let recorder = recorder ?? WatchAudioRecorder()
        let session = session ?? WatchAudioSessionController()
        self.recorder = recorder
        self.session = session
        self.recordingInventoryDidChange = recordingInventoryDidChange
        self.player = player ?? PCMStreamingPlayer(
            makeRenderer: { try EngineSpeechRenderer(sampleRate: $0, startingAt: $1) },
            activateSession: { intent in
                try session.activate(
                    for: intent == .beginPlayback ? .beginPlayback : .rebuildPlayback
                )
            },
            maximumReplySamples: Self.maximumReplySamples
        )
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.player.didChange = { [weak self] in self?.handlePlayerChange() }
        if observeNotifications { observeAudioSystem() }
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        recorderStartTask?.cancel()
        prepareTask?.cancel()
        routeRebuildTask?.cancel()
    }

    var isRecording: Bool { recorder.isRecording }
    var isStarting: Bool { recorder.isStarting }
    var isHolding: Bool { activeHoldID != nil }
    var level: CGFloat { recorder.level }
    var recordingErrorMessage: String? { recorder.errorMessage }
    var playingID: String? { player.playingID }
    var loadingID: String? { player.loadingID }
    var lastFinishedID: String? { player.lastFinishedID }
    var playbackErrorMessage: String? { player.errorMessage }

    func prepare() {
        guard prepareTask == nil, activeHoldID == nil, playingID == nil, loadingID == nil else { return }
        let epoch = lifecycleEpoch
        prepareTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.lifecycleEpoch == epoch else { return }
            do {
                try self.session.activate(for: .prepareCapture)
                await self.recorder.prepare()
                guard !Task.isCancelled, self.lifecycleEpoch == epoch else { return }
                if self.activeHoldID == nil, self.playingID == nil, self.loadingID == nil {
                    self.session.deactivate()
                }
            } catch {
                self.recorder.errorMessage = error.localizedDescription
            }
            if self.lifecycleEpoch == epoch { self.prepareTask = nil }
        }
    }

    func playReply(turnID: String, destination: KiboDestination, store: WatchStore) {
        player.play(id: "reply-\(turnID)") { fromSample, generation in
            try await store.speechStream(
                destination: destination,
                turnID: turnID,
                fromSample: fromSample,
                generation: generation
            )
        }
    }

    func resumeAutomaticPlayback() {
        automaticPlaybackSuspended = false
    }

    /// Idempotent across repeated DragGesture.onChanged events.
    func beginHold() {
        guard activeHoldID == nil else { return }
        prepareTask?.cancel()
        prepareTask = nil
        let holdID = UUID()
        let epoch = lifecycleEpoch
        activeHoldID = holdID
        player.pauseForCapture()
        recorderStartTask = Task { [weak self] in
            guard let self, !Task.isCancelled,
                  self.lifecycleEpoch == epoch, self.activeHoldID == holdID else { return }
            do { try self.session.activate(for: .beginCapture) }
            catch {
                guard self.lifecycleEpoch == epoch, self.activeHoldID == holdID else { return }
                self.recorder.errorMessage = error.localizedDescription
                self.activeHoldID = nil
                self.player.resumeAfterCapture()
                self.recorderStartTask = nil
                return
            }
            guard !Task.isCancelled,
                  self.lifecycleEpoch == epoch, self.activeHoldID == holdID else { return }
            let started = await self.recorder.start(holdID: holdID)
            guard !Task.isCancelled,
                  self.lifecycleEpoch == epoch, self.activeHoldID == holdID else {
                if started { self.recorder.cancel(holdID: holdID) }
                return
            }
            if !started {
                self.activeHoldID = nil
                self.player.resumeAfterCapture()
                if self.playingID == nil, self.loadingID == nil { self.session.deactivate() }
            }
            self.recorderStartTask = nil
        }
    }

    func endHold() -> WatchLocalRecording? {
        guard let holdID = activeHoldID else { return nil }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        let recording = recorder.stop(holdID: holdID)
        if recording == nil { recordingInventoryDidChange() }
        player.resumeAfterCapture()
        if playingID == nil, loadingID == nil { session.deactivate() }
        return recording
    }

    func cancelHold() {
        guard let holdID = activeHoldID else { return }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        recorder.cancel(holdID: holdID)
        player.resumeAfterCapture()
        if playingID == nil, loadingID == nil { session.deactivate() }
    }

    func conversationChanged() {
        stopForInactivity()
        automaticPlaybackSuspended = false
        lifecycleEpoch = UUID()
    }

    func stopReply() {
        player.stop()
    }

    func stopForInactivity() {
        lifecycleEpoch = UUID()
        prepareTask?.cancel()
        prepareTask = nil
        routeRebuildTask?.cancel()
        routeRebuildTask = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        if let holdID = activeHoldID {
            recorder.preserveForRecovery(holdID: holdID)
            recordingInventoryDidChange()
        }
        activeHoldID = nil
        recorder.resetAudioObjects()
        player.stop()
        session.deactivate()
    }

    func handleSystemEvent(_ event: WatchAudioSystemEvent) {
        switch event {
        case .playbackConfigurationChanged:
            guard activeHoldID == nil else { return }
            routeRebuildTask?.cancel()
            let epoch = lifecycleEpoch
            routeRebuildTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled, self.lifecycleEpoch == epoch else { return }
                self.player.rebuildAfterConfigurationChange()
                self.routeRebuildTask = nil
            }
        case .outputRouteUnavailable:
            teardownForSystemEvent()
            recorder.errorMessage = "Audio stopped because the headset or input route changed."
        case .interruptionBegan:
            teardownForSystemEvent()
            recorder.errorMessage = "Audio was interrupted. Tap and hold to begin again."
        case .mediaServicesReset:
            teardownForSystemEvent()
            recorder.errorMessage = "Audio services restarted. Tap and hold to begin again."
        }
    }

    private func teardownForSystemEvent() {
        // Set the gate before stopping the player: its synchronous change
        // callbacks must not interpret teardown as a new autoplay opportunity.
        automaticPlaybackSuspended = true
        lifecycleEpoch = UUID()
        prepareTask?.cancel()
        prepareTask = nil
        routeRebuildTask?.cancel()
        routeRebuildTask = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        if let holdID = activeHoldID {
            recorder.preserveForRecovery(holdID: holdID)
            recordingInventoryDidChange()
        }
        activeHoldID = nil
        recorder.resetAudioObjects()
        player.stop()
        session.deactivate()
    }

    private func handlePlayerChange() {
        objectWillChange.send()
        if activeHoldID == nil, player.playingID == nil, player.loadingID == nil {
            session.deactivate()
        }
    }

    private func observeAudioSystem() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemEvent(.playbackConfigurationChanged) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChangeNotification(note) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruptionNotification(note) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemEvent(.mediaServicesReset) }
        })
    }

    private func handleRouteChangeNotification(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if reason == .oldDeviceUnavailable {
            handleSystemEvent(.outputRouteUnavailable)
        } else if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
            handleSystemEvent(.playbackConfigurationChanged)
        }
    }

    private func handleInterruptionNotification(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        handleSystemEvent(.interruptionBegan)
    }
}
