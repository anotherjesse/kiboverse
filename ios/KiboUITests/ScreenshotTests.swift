import CryptoKit
import XCTest

/// Drives the redesigned navigation (conversation list → detail → talk mode)
/// and attaches screenshots. Run with:
///   xcodebuild test -project Kibo.xcodeproj -scheme Kibo \
///     -only-testing:KiboUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
/// then export attachments from the .xcresult with `xcrun xcresulttool`.
///
/// NOTE: never grant the simulator microphone permission (iOS 26.5 CoreAudio
/// bug hangs the app at launch when mic is granted); these tests never hold
/// the talk button (the thinking-state flick is a sub-second ask, the same
/// gesture ImageFlowTests uses safely with the mic revoked).
final class ScreenshotTests: XCTestCase {
    private let pendingConversationName = "PhonePending"

    @MainActor
    func testScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        waitForHome(app)
        sleep(2)
        attach(name: "home-conversation-list", app: app)

        // Home list → conversation detail.
        let row = app.staticTexts["General"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "General conversation row should exist")
        row.tap()
        dismissAlerts(app)

        // Wait for the timeline to render message cards.
        _ = app.staticTexts["Kibo"].firstMatch.waitForExistence(timeout: 20)
        sleep(2)
        attach(name: "conversation-detail", app: app)

        // Detail toolbar → full-screen push-to-talk mode.
        let talkModeButton = app.buttons["talk-mode-button"].firstMatch
        XCTAssertTrue(talkModeButton.waitForExistence(timeout: 10), "Talk mode button should exist")
        talkModeButton.tap()

        let close = app.buttons["talk-mode-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Talk mode should present")
        sleep(2)
        attach(name: "talk-mode", app: app)

        // Close talk mode and confirm we are back on the detail screen.
        close.tap()
        XCTAssertTrue(talkModeButton.waitForExistence(timeout: 10), "Should return to detail")
    }

    /// The phone constellation across its eight states, named to mirror the
    /// watch's `redesign-shots/round3/*` walk. The states the sim can drive for
    /// real are (pending via a seeded unclaimed clip, settled-history via the
    /// seeded "General"); every other state — the mic states the mic-revoked
    /// sim cannot open, the terminal failure the always-succeeding mock cannot
    /// produce, and thinking (its ~600ms mock window is not reliably catchable
    /// through XCUITest's post-gesture idle-sync, which releases only after the
    /// reply has already autoplayed) — is forced through the presentation-only
    /// `KIBO_UITEST_CENTER_STATE` override.
    @MainActor
    func testPhoneStateWalk() throws {
        let seed = MockSeed()
        let pendingConversation = seed.ensureConversation(
            name: pendingConversationName, withUnclaimedClip: true
        )
        XCTAssertNotNil(
            pendingConversation,
            "Should seed a pending conversation with an unclaimed clip via mock REST"
        )

        // The seeded "General" carries an unclaimed image — that is its "N
        // pending". Claim every unclaimed item via a POSTed turn and wait for
        // the log to settle so the settled-history shot renders history with
        // no pending indicator.
        seed.settleConversation(named: "General")

        captureRealPending()
        captureSettledHistory()

        captureOverride("recording", name: "phone-2-recording")
        captureOverride("swipeArmed", name: "phone-3-ask-armed")
        captureOverride("thinking", name: "phone-4-thinking")
        captureOverride("speaking", name: "phone-5-speaking")
        captureOverride("replyDone", name: "phone-6-reply-played")
        captureOverride("attention", name: "phone-8-failed-retry")
    }

    // MARK: - Walk captures

    /// phone-1-pending: the seeded conversation opens with an unclaimed clip
    /// as a bright coral star and an "N pending" status.
    @MainActor
    private func captureRealPending() {
        let app = XCUIApplication()
        app.launch()
        waitForHome(app)
        openTalkMode(app, conversation: pendingConversationName)
        sleep(2)
        attach(name: "phone-1-pending", app: app)
        app.terminate()
    }

    /// phone-7-settled-history: "General" after its unclaimed media was
    /// claimed (see `settleConversation`) — a sky of settled history markers
    /// with no "N pending" indicator.
    @MainActor
    private func captureSettledHistory() {
        let app = XCUIApplication()
        app.launch()
        waitForHome(app)
        openTalkMode(app, conversation: "General")
        sleep(2)
        attach(name: "phone-7-settled-history", app: app)
        app.terminate()
    }

    @MainActor
    private func captureOverride(_ stateName: String, name: String) {
        let app = XCUIApplication()
        app.launchEnvironment["KIBO_UITEST_CENTER_STATE"] = stateName
        app.launch()
        waitForHome(app)
        openTalkMode(app, conversation: "General")
        sleep(2)
        attach(name: name, app: app)
        app.terminate()
    }

    // MARK: - Navigation + gesture

    @MainActor
    private func openTalkMode(_ app: XCUIApplication, conversation: String) {
        let row = app.staticTexts[conversation].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(conversation) row should exist")
        row.tap()
        dismissAlerts(app)

        let talkModeButton = app.buttons["talk-mode-button"].firstMatch
        XCTAssertTrue(talkModeButton.waitForExistence(timeout: 15), "Talk mode button should exist")
        talkModeButton.tap()

        let close = app.buttons["talk-mode-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), "Talk mode should present")
    }

    // MARK: - Shared helpers

    /// The store surfaces connection errors as an alert; tap it away until
    /// the home list (project switcher in the navigation bar) is usable.
    @MainActor
    private func waitForHome(_ app: XCUIApplication, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ok = app.alerts.buttons["OK"].firstMatch
            if ok.exists {
                ok.tap()
                sleep(1)
                continue
            }
            if app.buttons["project-menu"].firstMatch.exists
                || app.navigationBars["Kibo"].exists { return }
            sleep(1)
        }
    }

    @MainActor
    private func dismissAlerts(_ app: XCUIApplication) {
        let ok = app.alerts.buttons["OK"].firstMatch
        while ok.exists {
            ok.tap()
            sleep(1)
        }
    }

    @MainActor
    private func attach(name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Minimal mock-kibod REST client for seeding walk fixtures. Runs on the host
/// against the same loopback mock the simulator uses. Synchronous by design
/// (semaphore-blocked) so the walk reads top-to-bottom. Internal (not private)
/// so `ImageFlowTests` can reuse `settleConversation` to make the shared "General"
/// conversation deterministic before driving the UI.
struct MockSeed {
    let base = URL(string: "http://127.0.0.1:3011")!
    let projectID = "kibo"

    /// Find (by name) or create a conversation, ensuring it carries one
    /// unclaimed clip so the app derives an `idle(pendingCount:)` state.
    /// Idempotent across runs: reuses the conversation and re-PUTs the same
    /// fixed clip bytes (same sha256 → no-op).
    func ensureConversation(name: String, withUnclaimedClip: Bool) -> String? {
        let id = findConversation(named: name) ?? createConversation(name: name)
        guard let id else { return nil }
        if withUnclaimedClip {
            putClip(conversationID: id, clipID: "phonependingclip1")
            // The mock never auto-claims a clip, but a past turn in this
            // durable store may already have claimed the fixed one — leaving
            // nothing pending. Guarantee genuine unclaimed media for the
            // pending shot by adding a second clip whenever the conversation
            // currently reads as settled.
            if unclaimedMediaCount(conversationID: id) == 0 {
                putClip(conversationID: id, clipID: "phonependingclip2")
            }
        }
        return id
    }

    /// Claim every unclaimed clip and image in a conversation by POSTing a
    /// turn, then block until the durable log reports it settled (no unclaimed
    /// media). The settled-history shot must show history with no "N pending".
    func settleConversation(named name: String) {
        guard let id = findConversation(named: name) else { return }
        submitTurn(conversationID: id)
        waitUntilSettled(conversationID: id)
    }

    private func submitTurn(conversationID: String) {
        let body = try? JSONSerialization.data(withJSONObject: ["turn_id": UUID().uuidString])
        _ = send(
            "POST", "/v1/projects/\(projectID)/conversations/\(conversationID)/turns",
            body: body, headers: ["Content-Type": "application/json"]
        )
    }

    private func waitUntilSettled(conversationID: String, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if unclaimedMediaCount(conversationID: conversationID) == 0 { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Media (clips + images) not yet claimed by any turn — the app's
    /// `askableItemCount` for a server-only conversation, recomputed host-side
    /// from the durable event log.
    private func unclaimedMediaCount(conversationID: String) -> Int {
        guard let data = get("/v1/projects/\(projectID)/conversations/\(conversationID)/events"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return 0 }
        var media = Set<String>()
        var claimed = Set<String>()
        for event in events {
            let kind = event["kind"] as? String
            if kind == "clip" || kind == "image", let id = event["id"] as? String {
                media.insert(id)
            }
            if kind == "turn" {
                for clip in (event["clips"] as? [String]) ?? [] { claimed.insert(clip) }
                for image in (event["images"] as? [String]) ?? [] { claimed.insert(image) }
            }
        }
        return media.subtracting(claimed).count
    }

    private func findConversation(named name: String) -> String? {
        guard let data = get("/v1/projects/\(projectID)/conversations"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["conversations"] as? [[String: Any]] else { return nil }
        return list.first { ($0["name"] as? String) == name }?["id"] as? String
    }

    private func createConversation(name: String) -> String? {
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        guard let data = send(
            "POST", "/v1/projects/\(projectID)/conversations",
            body: body, headers: ["Content-Type": "application/json"]
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? String
    }

    private func putClip(conversationID: String, clipID: String) {
        let wav = Self.makeWav()
        let sha = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
        _ = send(
            "PUT",
            "/v1/projects/\(projectID)/conversations/\(conversationID)/clips/\(clipID)",
            body: wav,
            headers: [
                "x-content-sha256": sha,
                "x-duration-ms": "1000",
                "x-peak-pct": "60"
            ]
        )
    }

    private func get(_ path: String) -> Data? {
        send("GET", path, body: nil, headers: [:])
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: Data?, headers: [String: String]) -> Data? {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    /// A minimal valid WAV (16-bit mono PCM, silent), matching kibod's
    /// `test_wav` header so `put_clip`'s `RIFF…WAVE` check accepts it.
    private static func makeWav() -> Data {
        let samples = [Int16](repeating: 0, count: 16)
        let dataLen = UInt32(samples.count * 2)
        var bytes = Data()
        bytes.append(contentsOf: Array("RIFF".utf8))
        bytes.append(contentsOf: le32(36 + dataLen))
        bytes.append(contentsOf: Array("WAVEfmt ".utf8))
        bytes.append(contentsOf: le32(16))
        bytes.append(contentsOf: le16(1))       // PCM
        bytes.append(contentsOf: le16(1))       // mono
        bytes.append(contentsOf: le32(16_000))  // sample rate
        bytes.append(contentsOf: le32(32_000))  // byte rate
        bytes.append(contentsOf: le16(2))       // block align
        bytes.append(contentsOf: le16(16))      // bits per sample
        bytes.append(contentsOf: Array("data".utf8))
        bytes.append(contentsOf: le32(dataLen))
        for sample in samples { bytes.append(contentsOf: le16(UInt16(bitPattern: sample))) }
        return bytes
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)
        ]
    }
}
