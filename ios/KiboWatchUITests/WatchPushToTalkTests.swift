import XCTest

@MainActor
final class WatchPushToTalkTests: XCTestCase {
    private struct EventEnvelope: Decodable {
        let events: [Event]
        let latestSeq: UInt64

        enum CodingKeys: String, CodingKey {
            case events
            case latestSeq = "latest_seq"
        }
    }

    private struct Event: Decodable {
        let seq: UInt64
        let kind: String
    }

    private var app: XCUIApplication!
    private var serverURL: String {
        ProcessInfo.processInfo.environment["KIBO_WATCH_TEST_SERVER_URL"]
            ?? "http://127.0.0.1:3001/"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-watchServerURL", serverURL,
            "-watchSelectedProjectID", "kibo",
            "-watchSelectedConversationID", "general"
        ]
        app.launch()
    }

    /// Hold 1s+, swipe up, release: the clip is saved and Kibo is asked in
    /// one gesture — no separate Ask tap.
    func testSwipeUpReleaseAsksKiboWithRecording() async throws {
        let baseline = try await fetchEvents().latestSeq
        let talkButton = app.buttons["watch-talk-button"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 10))
        XCTAssertTrue(talkButton.isHittable)

        let start = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.6))
        start.press(forDuration: 1.5, thenDragTo: end)

        let replyPlayed = app.staticTexts["Reply played"]
        XCTAssertTrue(
            replyPlayed.waitForExistence(timeout: 15),
            "Swipe-up release should submit the recording and autoplay the reply."
        )

        let newKinds = Set(try await fetchEvents().events
            .filter { $0.seq > baseline }
            .map(\.kind))
        XCTAssertTrue(newKinds.isSuperset(of: ["clip", "transcript", "turn", "reply", "speech_ready"]))
    }

    /// Sustained press saves the clip; a quick flick up afterwards asks Kibo
    /// with the pending clip (the Ask button is gone — swipe up IS ask).
    func testSustainedPushToTalkThenFlickUpAsksKibo() async throws {
        let baseline = try await fetchEvents().latestSeq
        let talkButton = app.buttons["watch-talk-button"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 10))
        XCTAssertTrue(talkButton.isHittable)

        talkButton.press(forDuration: 1.0)

        let pending = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'pending'")
        ).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Hold a little longer to record."].exists)

        // Flick: sub-second press released above the swipe threshold.
        let start = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.6))
        start.press(forDuration: 0.2, thenDragTo: end)

        let replyPlayed = app.staticTexts["Reply played"]
        XCTAssertTrue(
            replyPlayed.waitForExistence(timeout: 15),
            "The mock reply never completed Watch audio playback."
        )

        let newKinds = Set(try await fetchEvents().events
            .filter { $0.seq > baseline }
            .map(\.kind))
        XCTAssertTrue(newKinds.isSuperset(of: ["clip", "transcript", "turn", "reply", "speech_ready"]))
    }

    private func fetchEvents() async throws -> EventEnvelope {
        let base = URL(string: serverURL)!
        let url = base
            .appending(path: "v1")
            .appending(path: "projects")
            .appending(path: "kibo")
            .appending(path: "conversations")
            .appending(path: "general")
            .appending(path: "events")
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(EventEnvelope.self, from: data)
    }
}
