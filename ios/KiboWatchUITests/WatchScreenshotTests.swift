import XCTest

/// The watch design-iteration harness: an 8-state walk through the whole
/// push-to-talk lifecycle against a local mock kibod, capturing each state for
/// eyeball review against `redesign-shots/round3/*`.
///
/// Run with the mock kibod on the wired-up conversation, e.g.:
///   TEST_RUNNER_KIBO_WATCH_TEST_SERVER_URL="http://127.0.0.1:3011/" \
///   TEST_RUNNER_KIBO_WATCH_TEST_PROJECT_ID="kibo" \
///   TEST_RUNNER_KIBO_WATCH_TEST_CONVERSATION_ID="new-conversation-c7f17cfd" \
///   xcodebuild test -project Kibo.xcodeproj -scheme KiboWatch \
///     -only-testing:KiboWatchUITests/WatchScreenshotTests \
///     -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
///
/// Two capture channels, because the renderer is wall-clock driven and there is
/// no pixel-identical automation:
///   1. XCTAttachment (exported from the .xcresult) for every state we can hold
///      or land on — including the transient recording/ask-armed states, which
///      we hold for a few seconds and grab from a background thread mid-hold.
///   2. Stage markers on stdout (`KIBO_WALK: <name> …`) so a host-side
///      `simctl io screenshot` burst loop can correlate its frames with the
///      truly app-driven transients (thinking/speaking, ~0.6s each on mock).
///
/// `failed-retry` is env-gated in a separate method: plain mock kibod
/// transcribes unconditionally, so a terminal failure needs the host to restart
/// kibod with bogus Gemini credentials first (see `testFailedRetryFixture`).
final class WatchScreenshotTests: XCTestCase {
    private var serverURL: String {
        ProcessInfo.processInfo.environment["KIBO_WATCH_TEST_SERVER_URL"]
            ?? "http://127.0.0.1:3011/"
    }
    private var projectID: String {
        ProcessInfo.processInfo.environment["KIBO_WATCH_TEST_PROJECT_ID"] ?? "kibo"
    }
    private var conversationID: String {
        ProcessInfo.processInfo.environment["KIBO_WATCH_TEST_CONVERSATION_ID"]
            ?? "new-conversation-c7f17cfd"
    }

    /// Screenshots captured off the test thread while a gesture blocks it,
    /// flushed as attachments back on the main thread once the gesture returns.
    private var deferredShots: [(name: String, shot: XCUIScreenshot)] = []
    private let shotLock = NSLock()

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-watchServerURL", serverURL,
            "-watchSelectedProjectID", projectID,
            "-watchSelectedConversationID", conversationID
        ]
        return app
    }

    /// pending → recording → ask-armed → thinking → speaking → reply-played →
    /// settled-history. (failed-retry is `testFailedRetryFixture`, env-gated.)
    @MainActor
    func testEightStateWalk() throws {
        let app = makeApp()
        app.launch()

        let talkButton = app.buttons["watch-talk-button"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 15))
        sleep(2)
        stage("idle begin")
        attach("walk-0-idle", app)
        stage("idle end")

        // --- recording + pending -------------------------------------------
        // A straight 3s hold: held past the 1s record threshold with no swipe,
        // so on release it SAVES the clip (→ "N pending"). Mid-hold the screen
        // is the recording state; grab it from a background thread.
        stage("recording begin")
        scheduleShot("walk-2-recording", after: 1.5)
        talkButton.press(forDuration: 3.0)
        flushShots()
        stage("recording end")

        let pending = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'pending'")
        ).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Held clip should read 'N pending'.")
        stage("pending begin")
        attach("walk-1-pending", app)
        stage("pending end")

        // --- ask-armed → thinking → speaking → reply-played ----------------
        // Press, drag up past the swipe threshold, and HOLD there: the gesture
        // is armed for ~3s (grabbed mid-hold), then on release — held past 1s
        // and swiped — it saves the clip AND asks, driving thinking → speaking
        // → reply-played on its own.
        let start = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = talkButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.6))
        stage("ask-armed begin")
        scheduleShot("walk-3-ask-armed", after: 1.8)
        // The ask fires on release (~3.2s into this gesture); the transients —
        // thinking (~1s) and speaking (~0.6s on mock) — blow past XCUITest's
        // per-query snapshot, so grab the whole post-release window as a fast
        // background pixel burst. XCUIScreen capture is the ONLY channel that
        // sees the watch app: host-side `simctl io screenshot` grabs the watch
        // face, not the foreground app, on the watchOS simulator.
        scheduleShotSeries(prefix: "askflow", count: 34, interval: 0.2, startAfter: 3.4)
        start.press(
            forDuration: 0.1, thenDragTo: end,
            withVelocity: .default, thenHoldForDuration: 3.0
        )
        stage("ask-armed end (released → asking; askflow burst running)")

        let replyPlayed = app.staticTexts["Reply played"]
        XCTAssertTrue(
            replyPlayed.waitForExistence(timeout: 20),
            "Swipe-up release should submit the recording and autoplay the reply."
        )
        stage("reply-played begin")
        attach("walk-6-reply-played", app)
        stage("reply-played end")

        // Let the background askflow burst finish, then flush ask-armed + the
        // thinking/speaking window frames (askflow-NN) as attachments; the
        // clean thinking and speaking stills are picked from those.
        sleep(4)
        flushShots()
        stage("askflow burst flushed")

        // --- settled-history -----------------------------------------------
        // Let the events settle: the constellation now holds the asked clips
        // and the reply as seen history markers.
        sleep(3)
        stage("settled-history begin")
        attach("walk-7-settled-history", app)
        stage("settled-history end")
    }

    /// walk-8-failed-retry — env-gated because plain mock kibod transcribes
    /// unconditionally (`kibod/src/ai.rs`), so it can never produce a terminal
    /// failure. The host must stage the fixture first:
    ///
    ///   FIXTURE PROCEDURE (host):
    ///   1. Stop the mock kibod.
    ///   2. Restart it with terminal-failure credentials — a bogus Gemini key
    ///      WITHOUT the proxy fails on the first attempt (Gemini 400); the
    ///      proxy variant only fails terminally after ~3 retries / ~7s:
    ///        KIBO_BIND=127.0.0.1:3011 KIBO_DATA_DIR=$(mktemp -d) \
    ///          GEMINI_API_KEY=bogus RUST_LOG=info,tower_http=debug \
    ///          ./target/debug/kibod > kibod.log 2>&1 &
    ///   3. Re-run with KIBO_WATCH_FAILURE_FIXTURE=1 and the same
    ///      TEST_RUNNER_KIBO_WATCH_TEST_* env as the main walk.
    ///
    /// Recording a clip is enough: kibod transcribes clips on upload, that
    /// transcription fails terminally, the marker goes amber, and the Retry
    /// affordance (watch-retry-button) appears. We capture and tap nothing —
    /// Retry would just re-fail against the bogus key.
    @MainActor
    func testFailedRetryFixture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIBO_WATCH_FAILURE_FIXTURE"] == "1",
            "Skipped: host must restart kibod with bogus Gemini credentials first "
            + "(set KIBO_WATCH_FAILURE_FIXTURE=1). See the fixture procedure above."
        )
        let app = makeApp()
        app.launch()

        let talkButton = app.buttons["watch-talk-button"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 15))

        stage("failed-retry: recording clip")
        talkButton.press(forDuration: 1.5)

        let retry = app.buttons["watch-retry-button"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 25),
            "Terminal transcription failure should surface the Retry affordance."
        )
        sleep(1)
        stage("failed-retry begin")
        attach("walk-8-failed-retry", app)
        stage("failed-retry end")
    }

    // MARK: - Capture helpers

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Grab the screen `delay` seconds from now, off the test thread, so a
    /// blocking press/hold — or an app-driven transient — can be photographed
    /// without waiting on the (slow) accessibility query path.
    private func scheduleShot(_ name: String, after delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            let shot = XCUIScreen.main.screenshot()
            guard let self else { return }
            self.shotLock.lock()
            self.deferredShots.append((name, shot))
            self.shotLock.unlock()
        }
    }

    /// A fast fixed-cadence burst of background captures — the reliable way to
    /// catch sub-second, app-driven states (thinking/speaking) on the watch
    /// simulator, where the only capture path that sees the app is XCUIScreen.
    private func scheduleShotSeries(
        prefix: String, count: Int, interval: TimeInterval, startAfter: TimeInterval
    ) {
        for i in 0..<count {
            scheduleShot(
                String(format: "%@-%02d", prefix, i),
                after: startAfter + Double(i) * interval
            )
        }
    }

    @MainActor
    private func flushShots() {
        shotLock.lock()
        let shots = deferredShots
        deferredShots.removeAll()
        shotLock.unlock()
        for entry in shots {
            let attachment = XCTAttachment(screenshot: entry.shot)
            attachment.name = entry.name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// A stage marker on stdout for host-side burst-loop correlation.
    private func stage(_ label: String) {
        NSLog("KIBO_WALK: \(label)")
        print("KIBO_WALK: \(label)")
    }
}
