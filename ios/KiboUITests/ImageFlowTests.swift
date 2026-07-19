import XCTest

/// End-to-end image flow against a local mock kibod
/// (`KIBO_AI_MODE=mock`): attach a photo from the simulator's library →
/// pending "not asked yet" card → swipe-up ask → image card + mock reply.
///
/// Prerequisites (same as ScreenshotTests): sim serverURL written via
/// `simctl spawn <sim> defaults write com.anotherjesse.kibo serverURL …`, a
/// conversation named "General" seeded, and microphone permission REVOKED
/// (iOS 26.5 CoreAudio deadlock when granted).
final class ImageFlowTests: XCTestCase {
    @MainActor
    func testAttachFromLibraryThenAskRendersImageCardAndMockReply() throws {
        // The mock kibod is long-running and durable; a prior run can leave
        // unclaimed media in "General", which would make this run's ask claim
        // more than the single image it attaches (reply "I see 2 image(s)")
        // and break the image-only-turn assertions. Settle the conversation
        // via REST first so the one image attached below is the only unclaimed
        // item and the mock reply is deterministically "I see 1 image".
        MockSeed().settleConversation(named: "General")

        let app = XCUIApplication()
        app.launch()

        waitForHome(app)

        let row = app.staticTexts["General"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "General conversation row should exist")
        row.tap()
        dismissAlerts(app)

        let attachButton = app.buttons["attach-button"].firstMatch
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10), "Attach button should exist")
        attachButton.tap()

        let libraryEntry = app.buttons["Photo Library"].firstMatch
        XCTAssertTrue(libraryEntry.waitForExistence(timeout: 5), "Attach menu should offer the photo library")
        // Camera is hidden on the simulator by construction.
        XCTAssertFalse(app.buttons["Take Photo"].exists, "Camera entry must be hidden in the simulator")
        libraryEntry.tap()

        // PHPicker runs out of process; its grid is bridged into the app's
        // accessibility hierarchy. Timeline cards and glyphs behind the picker
        // sheet still exist in that hierarchy but are not hittable, so scan
        // for the first hittable, cell-sized image — that is a picker photo,
        // even when the conversation behind the sheet already has images.
        let photo = try waitForPickerPhoto(app)
        // Remote-view cells can report isHittable == false while taps on
        // their coordinates land fine — element.tap() refuses, so tap the
        // cell's center by coordinate.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"].firstMatch
        if add.waitForExistence(timeout: 5) {
            add.tap()
        } else {
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
        }

        // Normalize → spool → upload → server event → poll: the unclaimed
        // image appears as a "not asked yet" card.
        let pendingCard = app.staticTexts["You · not asked yet"].firstMatch
        XCTAssertTrue(
            pendingCard.waitForExistence(timeout: 30),
            "The uploaded image should appear as a pending card"
        )
        let renderedImage = app.descendants(matching: .any)["timeline-image"].firstMatch
        XCTAssertTrue(renderedImage.waitForExistence(timeout: 15), "The photo itself should render")
        sleep(2)
        attach(name: "image-pending-card", app: app)

        // Swipe-up flick on the mic = ask with what's pending (image-only ask).
        askKiboWithFlick(app)
        var reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "I see 1 image")
        ).firstMatch
        if !reply.waitForExistence(timeout: 15) {
            // One retry: a flick can occasionally be swallowed by scrolling.
            dismissAlerts(app)
            askKiboWithFlick(app)
            reply = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "I see 1 image")
            ).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 30), "Mock reply for an image-only turn should render")
        }

        XCTAssertTrue(renderedImage.exists, "The image card remains after the turn claims it")
        sleep(2)
        attach(name: "image-turn-with-reply", app: app)
    }

    @MainActor
    private func waitForPickerPhoto(
        _ app: XCUIApplication, timeout: TimeInterval = 20
    ) throws -> XCUIElement {
        // Remote-view picker cells report isHittable == false even though
        // taps on them work, so select by the grid cell's shape instead: a
        // roughly square image well larger than any timeline glyph. (On this
        // iOS the cells carry the identifier "PXGGridLayout-Info".)
        func isPickerCell(_ element: XCUIElement) -> Bool {
            if element.identifier == "timeline-image" { return false }
            let frame = element.frame
            return frame.width > 100 && abs(frame.width - frame.height) < 30
        }
        // Primary: the grid cells carry a stable identifier on this iOS, and
        // a firstMatch query re-resolves at use time — the only lookup that
        // survives the remote grid's index churn (per-index re-resolution
        // sees nothing; enumerated snapshots go stale mid-scan).
        let byIdentifier = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        if byIdentifier.waitForExistence(timeout: timeout / 2) { return byIdentifier }
        // Fallback for identifier drift on future iOS: shape-based sweep over
        // a fresh snapshot per attempt.
        let deadline = Date().addingTimeInterval(timeout / 2)
        while Date() < deadline {
            for element in app.images.allElementsBoundByIndex
            where isPickerCell(element) {
                return element
            }
            sleep(1)
        }
        attach(name: "picker-debug", app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "picker-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Picker should show sample photos")
        throw XCTSkip("No picker photo appeared")
    }

    @MainActor
    private func askKiboWithFlick(_ app: XCUIApplication) {
        let mic = app.buttons["talk-button"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "Mic button should exist")
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2.5))
        // Sub-second press + upward swipe = "ask with what's pending".
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
    }

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
