import XCTest

/// Drives the app to the conversation view and attaches a screenshot.
/// Run with:
///   xcodebuild test -project Kibo.xcodeproj -scheme Kibo \
///     -only-testing:KiboUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
/// then export attachments from the .xcresult with `xcrun xcresulttool`.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testConversationScreenshot() throws {
        let app = XCUIApplication()
        app.launch()

        dismissAlerts(app)
        app.tabBars.buttons["Conversations"].tap()
        dismissAlerts(app)

        // On iPhone the split view may land on the conversation list;
        // drill into "General" if it's showing.
        let row = app.staticTexts["General"].firstMatch
        if row.waitForExistence(timeout: 8) { row.tap() }

        // Wait for the timeline to render message cards.
        _ = app.staticTexts["Kibo"].firstMatch.waitForExistence(timeout: 20)
        sleep(2)

        attach(name: "conversation", app: app)
    }

    /// The store surfaces connection errors as an alert; tap it away until
    /// the app has (re)connected and the tab bar is usable.
    @MainActor
    private func dismissAlerts(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ok = app.alerts.buttons["OK"].firstMatch
            if ok.exists {
                ok.tap()
                sleep(1)
                continue
            }
            if app.tabBars.buttons["Conversations"].isHittable { return }
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
