import XCTest

/// Drives the redesigned navigation (conversation list → detail → talk mode)
/// and attaches screenshots. Run with:
///   xcodebuild test -project Kibo.xcodeproj -scheme Kibo \
///     -only-testing:KiboUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
/// then export attachments from the .xcresult with `xcrun xcresulttool`.
///
/// NOTE: never grant the simulator microphone permission (iOS 26.5 CoreAudio
/// bug hangs the app at launch when mic is granted); these tests never touch
/// the hold-to-talk button.
final class ScreenshotTests: XCTestCase {
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
