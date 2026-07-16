@preconcurrency import AVFoundation
import Combine
import Foundation

enum AudioSessionIntent: Equatable {
    case prepareCapture
    case beginCapture
    case beginPlayback
    case rebuildPlayback
}

enum AudioSystemEvent: Equatable {
    case outputRouteUnavailable
    case playbackConfigurationChanged
    case interruptionBegan
    case mediaServicesReset
}

@MainActor
protocol AudioSessionControlling: AnyObject {
    func activate(for intent: AudioSessionIntent) throws
    func deactivate()
}

@MainActor
protocol AudioCapturing: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var isRecording: Bool { get }
    var isStarting: Bool { get }
    var level: CGFloat { get }
    var errorMessage: String? { get set }
    func prepare() async
    func start(holdID: UUID) async -> Bool
    func stop(holdID: UUID) -> LocalRecording?
    func cancel(holdID: UUID?)
    func preserveForRecovery(holdID: UUID?)
    func resetAudioObjects()
}

extension AudioRecorder: AudioCapturing {}

@MainActor
final class AudioSessionController: AudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activate(for intent: AudioSessionIntent) throws {
        if intent == .rebuildPlayback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Sole UI-facing audio policy owner. The recorder, transport, and renderer
/// stay separate mechanisms; this type defines only their legal ordering.
@MainActor
final class AudioCoordinator: ObservableObject {
    private let recorder: any AudioCapturing
    private let player: SpeechPlayer
    private let session: any AudioSessionControlling
    private let recordingInventoryDidChange: @MainActor () -> Void
    private var activeHoldID: UUID?
    private var recorderStartTask: Task<Void, Never>?
    private var configurationRebuildTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        recorder: (any AudioCapturing)? = nil,
        session: (any AudioSessionControlling)? = nil,
        player: SpeechPlayer? = nil,
        observeNotifications: Bool = true,
        recordingInventoryDidChange: @escaping @MainActor () -> Void = {}
    ) {
        let recorder = recorder ?? AudioRecorder()
        let session = session ?? AudioSessionController()
        self.recorder = recorder
        self.session = session
        self.recordingInventoryDidChange = recordingInventoryDidChange
        self.player = player ?? SpeechPlayer(activateSession: { try session.activate(for: $0) })
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.player.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        if observeNotifications { observeAudioSystem() }
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        recorderStartTask?.cancel()
        configurationRebuildTask?.cancel()
    }

    var isRecording: Bool { recorder.isRecording }
    var isStarting: Bool { recorder.isStarting }
    var isHolding: Bool { activeHoldID != nil }
    var level: CGFloat { recorder.level }
    var recordingErrorMessage: String? { recorder.errorMessage }
    var playingID: String? { player.playingID }
    var loadingID: String? { player.loadingID }
    var playbackErrorMessage: String? {
        get { player.errorMessage }
        set { player.errorMessage = newValue }
    }

    func prepare() async {
        do {
            try session.activate(for: .prepareCapture)
            await recorder.prepare()
        } catch {
            recorder.errorMessage = error.localizedDescription
        }
    }

    func playReply(turnID: String, store: AppStore) {
        player.playReply(turnID: turnID, store: store)
    }

    func toggleReply(turnID: String, store: AppStore) {
        player.toggleReply(turnID: turnID, store: store)
    }

    func toggleClip(clipID: String, store: AppStore) {
        player.toggleClip(clipID: clipID, store: store)
    }

    /// Idempotent across repeated DragGesture.onChanged events.
    func beginHold() {
        guard activeHoldID == nil else { return }
        let holdID = UUID()
        activeHoldID = holdID
        player.pauseForRecording()
        recorderStartTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do { try self.session.activate(for: .beginCapture) }
            catch {
                self.recorder.errorMessage = error.localizedDescription
                self.player.resumeAfterRecording()
                if self.activeHoldID == holdID { self.activeHoldID = nil }
                self.recorderStartTask = nil
                return
            }
            let started = await self.recorder.start(holdID: holdID)
            guard !Task.isCancelled else {
                if started { self.recorder.cancel(holdID: holdID) }
                return
            }
            if !started, self.activeHoldID == holdID {
                self.player.resumeAfterRecording()
                self.activeHoldID = nil
            }
            self.recorderStartTask = nil
        }
    }

    func endHold() -> LocalRecording? {
        guard let holdID = activeHoldID else { return nil }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        let recording = recorder.stop(holdID: holdID)
        if recording == nil { recordingInventoryDidChange() }
        restorePlaybackAfterCapture()
        Task { await prepare() }
        return recording
    }

    func cancelHold() {
        cancelActiveHold(resumePlayback: true, prepareAfterward: true)
    }

    private func cancelActiveHold(resumePlayback: Bool, prepareAfterward: Bool) {
        guard let holdID = activeHoldID else { return }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        recorder.cancel(holdID: holdID)
        if resumePlayback {
            restorePlaybackAfterCapture()
        } else {
            player.stop()
        }
        if prepareAfterward { Task { await prepare() } }
    }

    func stop() {
        preserveActiveHold()
        player.stop()
    }

    func stopForInactivity() {
        preserveActiveHold()
        player.stop()
        session.deactivate()
    }

    private func preserveActiveHold() {
        guard let holdID = activeHoldID else { return }
        activeHoldID = nil
        recorderStartTask?.cancel()
        recorderStartTask = nil
        recorder.preserveForRecovery(holdID: holdID)
        recordingInventoryDidChange()
    }

    private func restorePlaybackAfterCapture() {
        player.resumeAfterRecording()
    }

    private func observeAudioSystem() {
        let center = NotificationCenter.default
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
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemEvent(.playbackConfigurationChanged) }
        })
    }

    private func handleRouteChangeNotification(_ notification: Notification) {
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if reason == .oldDeviceUnavailable {
            handleSystemEvent(.outputRouteUnavailable)
            return
        }
        if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
            handleSystemEvent(.playbackConfigurationChanged)
        }
    }

    private func handleInterruptionNotification(_ notification: Notification) {
        guard let event = Self.interruptionEvent(from: notification) else { return }
        handleSystemEvent(event)
    }

    static func interruptionEvent(from notification: Notification) -> AudioSystemEvent? {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return nil }
        return .interruptionBegan
    }

    func handleSystemEvent(_ event: AudioSystemEvent) {
        switch event {
        case .outputRouteUnavailable:
            configurationRebuildTask?.cancel()
            configurationRebuildTask = nil
            let wasHolding = activeHoldID != nil
            preserveActiveHold()
            player.stop() // Never move private headphone audio onto the speaker implicitly.
            if wasHolding {
                recorder.errorMessage = "The recording stopped because the audio input changed."
            }
        case .playbackConfigurationChanged:
            configurationRebuildTask?.cancel()
            configurationRebuildTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.player.rebuildAfterRouteChange()
                self.configurationRebuildTask = nil
            }
        case .interruptionBegan:
            configurationRebuildTask?.cancel()
            configurationRebuildTask = nil
            let wasHolding = activeHoldID != nil
            preserveActiveHold()
            player.stop()
            if wasHolding {
                recorder.errorMessage = "The recording was interrupted. Please try again."
            }
        case .mediaServicesReset:
            configurationRebuildTask?.cancel()
            configurationRebuildTask = nil
            preserveActiveHold()
            recorder.resetAudioObjects()
            player.stop()
            recorder.errorMessage = "Audio services restarted. Tap and hold to begin again."
        }
    }
}
