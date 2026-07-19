@preconcurrency import AVFoundation
import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// The pure notification→event mappers `AudioSystemObserver` forwards
/// through. Migrated from `KiboAPITests.testInterruptionPolicyOnlyMapsBeganNotifications`
/// and retargeted at the shared seam; route-change coverage is new. No
/// coordinator, no NotificationCenter — these are value-in, value-out.
final class AudioEventMappingTests: XCTestCase {

    // MARK: - interruptionEvent

    func testInterruptionEventMapsBeganToInterruptionBegan() {
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        XCTAssertEqual(AudioSystemObserver.interruptionEvent(from: began), .interruptionBegan)
    }

    func testInterruptionEventIgnoresEndedNotifications() {
        let ended = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )

        XCTAssertNil(AudioSystemObserver.interruptionEvent(from: ended))
    }

    func testInterruptionEventIgnoresNotificationsWithoutAPayload() {
        let empty = Notification(name: AVAudioSession.interruptionNotification, userInfo: nil)

        XCTAssertNil(AudioSystemObserver.interruptionEvent(from: empty))
    }

    // MARK: - routeChangeEvent

    func testRouteChangeEventMapsOldDeviceUnavailableToOutputRouteUnavailable() {
        let notification = routeChangeNotification(reason: .oldDeviceUnavailable)

        XCTAssertEqual(AudioSystemObserver.routeChangeEvent(from: notification), .outputRouteUnavailable)
    }

    func testRouteChangeEventMapsNewDeviceAvailableToPlaybackConfigurationChanged() {
        let notification = routeChangeNotification(reason: .newDeviceAvailable)

        XCTAssertEqual(AudioSystemObserver.routeChangeEvent(from: notification), .playbackConfigurationChanged)
    }

    func testRouteChangeEventMapsRouteConfigurationChangeToPlaybackConfigurationChanged() {
        let notification = routeChangeNotification(reason: .routeConfigurationChange)

        XCTAssertEqual(AudioSystemObserver.routeChangeEvent(from: notification), .playbackConfigurationChanged)
    }

    func testRouteChangeEventIgnoresUnrelatedReasons() {
        for reason: AVAudioSession.RouteChangeReason in [.categoryChange, .override, .unknown] {
            XCTAssertNil(AudioSystemObserver.routeChangeEvent(from: routeChangeNotification(reason: reason)))
        }
    }

    func testRouteChangeEventIgnoresNotificationsWithoutAPayload() {
        let empty = Notification(name: AVAudioSession.routeChangeNotification, userInfo: nil)

        XCTAssertNil(AudioSystemObserver.routeChangeEvent(from: empty))
    }

    private func routeChangeNotification(reason: AVAudioSession.RouteChangeReason) -> Notification {
        Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }
}
