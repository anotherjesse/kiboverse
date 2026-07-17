import XCTest

/// The honest cross-process spool test: a REAL share from the Photos app into
/// the KiboShare extension (separate process, writing through the app-group
/// spool), then a Kibo launch whose sweep uploads the deposited attachment to
/// the local mock kibod.
///
/// Prerequisites match ImageFlowTests (local mock kibod, seeded "General",
/// mic revoked). Photos-app navigation is inherently version-fragile, so the
/// PATH INTO the share sheet degrades to XCTSkip when this iOS's Photos UI
/// cannot be walked — but the skip boundary is the share sheet itself: the
/// moment the sheet is OPEN, Kibo's absence from the activity list is a hard
/// failure (broken embedding, activation rule, signing, or extension
/// registration — exactly the Phase D regression this test exists to catch),
/// and every assertion after tapping Kibo's row is hard too.
///
/// Observed on iOS 26.5 sims: passes fully from a clean Photos state; after
/// a run has already shared once, Photos relaunches into a state where the
/// detail "Share" button is not exposed and the test skips ("share path not
/// drivable") — that skip happens BEFORE the sheet, so it is Apple-UI drift,
/// never a Kibo regression. The seam stays deterministically covered by
/// ShareExtensionSeamTests and ImageFlowTests.
final class ShareFlowTests: XCTestCase {
    @MainActor
    func testShareFromPhotosDepositsAttachmentThatKiboUploadsOnLaunch() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        dismissSheets(photos)
        // Photos restores its previous view; walk back out of a leftover
        // share sheet or photo detail toward the library grid.
        for label in ["Cancel", "Close"] {
            let leftover = photos.buttons[label].firstMatch
            if leftover.exists { leftover.tap(); sleep(1) }
        }
        for _ in 0..<2 where photos.navigationBars.buttons["Back"].firstMatch.exists {
            photos.navigationBars.buttons["Back"].firstMatch.tap()
            sleep(1)
        }

        // A photo cell in the library grid.
        guard let cell = firstPhotoCell(photos) else {
            throw XCTSkip("Photos grid not found on this iOS — share path not drivable")
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let share = photos.buttons["Share"].firstMatch
        guard share.waitForExistence(timeout: 8) else {
            throw XCTSkip("Photos share button not found — share path not drivable")
        }
        share.tap()

        // The activity row bridges other processes' UI into this hierarchy.
        // Skip is only legitimate up to here: if the sheet itself never
        // opens, that is still Apple's UI. Once it IS open, Kibo's absence
        // is a Kibo regression and must fail loudly.
        let kiboActivity = photos.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Kibo")).firstMatch
        guard waitForShareSheet(photos, kiboActivity: kiboActivity, timeout: 10) else {
            throw XCTSkip("The share sheet never opened — share path not drivable")
        }
        if !kiboActivity.waitForExistence(timeout: 10) {
            // The app-activity row can fold Kibo past the visible edge; give
            // it a scroll before judging.
            for _ in 0..<2 where !kiboActivity.exists {
                let activityRow = photos.collectionViews.firstMatch
                if activityRow.exists { activityRow.swipeLeft() } else { photos.swipeLeft() }
                sleep(1)
            }
        }
        guard kiboActivity.exists else {
            XCTFail(
                "The share sheet is open but Kibo is missing from the activity list — "
                    + "broken share-extension embedding, activation rule, signing, or "
                    + "registration. This is a Kibo regression, never Apple UI drift."
            )
            return
        }
        kiboActivity.tap()

        // From here on this is OUR UI — hard assertions only.
        let save = photos.buttons["share-save"].firstMatch
        XCTAssertTrue(
            save.waitForExistence(timeout: 10),
            "KiboShare's save button should appear inside the share sheet"
        )
        XCTAssertTrue(
            photos.staticTexts["share-destination"].exists
                || photos.buttons["share-destination"].exists
                || photos.otherElements["share-destination"].exists,
            "The cached-destination picker should be visible"
        )
        save.tap()

        let saved = photos.staticTexts["share-saved-message"].firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 15),
            "The extension should confirm: saved, sends when you open Kibo"
        )
        XCTAssertTrue(
            saved.label.contains("sends when you open Kibo"),
            "The confirmation copy must be honest about the handoff"
        )

        // The main app is the sole uploader: launching it sweeps the shared
        // spool and uploads to the mock server, so a new person card appears.
        let app = XCUIApplication()
        app.launch()
        waitForHome(app)
        let row = app.staticTexts["General"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "General conversation row should exist")
        row.tap()
        dismissSheets(app)
        let uploaded = app.descendants(matching: .any)["timeline-image"].firstMatch
        XCTAssertTrue(
            uploaded.waitForExistence(timeout: 30),
            "The shared photo should upload on launch and render in the timeline"
        )
        attach(name: "shared-photo-uploaded", app: app)
    }

    @MainActor
    private func firstPhotoCell(_ photos: XCUIApplication) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let images = photos.images
            for index in 0..<images.count {
                let element = images.element(boundBy: index)
                guard element.exists else { continue }
                let frame = element.frame
                if frame.width > 80, abs(frame.width - frame.height) < 60,
                   frame.minY > 40 {
                    return element
                }
            }
            let cells = photos.collectionViews.cells
            for index in 0..<min(cells.count, 3) {
                let element = cells.element(boundBy: index)
                guard element.exists else { continue }
                let frame = element.frame
                if frame.width > 80, frame.height > 80 { return element }
            }
            sleep(1)
        }
        return nil
    }

    /// True once the share sheet itself is on screen — recognized by Kibo's
    /// own row or by sheet-native furniture (the activity list container,
    /// Copy, Options, Edit Actions…). Photo-detail chrome never matches.
    @MainActor
    private func waitForShareSheet(
        _ photos: XCUIApplication, kiboActivity: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kiboActivity.exists { return true }
            if photos.otherElements["ActivityListView"].firstMatch.exists { return true }
            for label in ["Copy", "Options", "Edit Actions…"] {
                if photos.buttons[label].firstMatch.exists
                    || photos.cells[label].firstMatch.exists
                    || photos.staticTexts[label].firstMatch.exists {
                    return true
                }
            }
            sleep(1)
        }
        return false
    }

    @MainActor
    private func dismissSheets(_ app: XCUIApplication) {
        for label in ["Continue", "OK", "Not Now", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.exists { button.tap(); sleep(1) }
        }
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
    private func attach(name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
