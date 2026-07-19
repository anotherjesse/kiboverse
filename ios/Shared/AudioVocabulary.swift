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

/// Subscribes to the AVAudioSession/AVAudioEngine notifications both audio
/// coordinators react to and forwards them through pure static mappers.
/// Registration order (route, interruption, media reset, engine config) is
/// behavior-neutral — each observer targets a distinct notification name —
/// but is called out because the phone and watch coordinators previously
/// registered in different orders before this extraction.
@MainActor
final class AudioSystemObserver {
    private var notificationTokens: [NSObjectProtocol] = []

    init(onEvent: @escaping @MainActor (AudioSystemEvent) -> Void) {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let event = Self.routeChangeEvent(from: note) else { return }
            Task { @MainActor in onEvent(event) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let event = Self.interruptionEvent(from: note) else { return }
            Task { @MainActor in onEvent(event) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            Task { @MainActor in onEvent(.mediaServicesReset) }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onEvent(.playbackConfigurationChanged) }
        })
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    nonisolated static func interruptionEvent(from notification: Notification) -> AudioSystemEvent? {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return nil }
        return .interruptionBegan
    }

    nonisolated static func routeChangeEvent(from notification: Notification) -> AudioSystemEvent? {
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if reason == .oldDeviceUnavailable {
            return .outputRouteUnavailable
        }
        if reason == .newDeviceAvailable || reason == .routeConfigurationChange {
            return .playbackConfigurationChanged
        }
        return nil
    }
}
