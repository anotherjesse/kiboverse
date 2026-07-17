import XCTest

/// Captures the watch app's main screens for UX review.
/// Run with:
///   xcodebuild test -project Kibo.xcodeproj -scheme KiboWatch \
///     -only-testing:KiboWatchUITests/WatchScreenshotTests \
///     -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
final class WatchScreenshotTests: XCTestCase {
    private var serverURL: String {
        ProcessInfo.processInfo.environment["KIBO_WATCH_TEST_SERVER_URL"]
            ?? "http://127.0.0.1:3010/"
    }

    @MainActor
    func testScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-watchServerURL", serverURL,
            "-watchSelectedProjectID", "kibo",
            "-watchSelectedConversationID", "general-1a467f7b"
        ]
        app.launch()

        let talkButton = app.buttons["watch-talk-button"]
        _ = talkButton.waitForExistence(timeout: 15)
        sleep(2)
        attach(name: "watch-01-main", app: app)

        // Conversation/project selection screen.
        let selectionLink = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'General' OR label CONTAINS 'Choose'")
        ).firstMatch
        if selectionLink.exists {
            selectionLink.tap()
            sleep(2)
            attach(name: "watch-02-selection", app: app)
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        attach(name: "watch-03-main-again", app: app)
    }

    @MainActor
    private func attach(name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
