import XCTest

/// Run only on a simulator seeded with disposable photos and photo access granted.
final class PhotoSlimUITests: XCTestCase {
    private var reviewedOriginalID = ""
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if !targetEnvironment(simulator)
        throw XCTSkip("These tests use disposable simulator media only.")
        #endif
        continueAfterFailure = false
    }

    private func launchWithPhotoAccess(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.resetAuthorizationStatus(for: .photos)
        addUIInterruptionMonitor(withDescription: "Photo access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'full access' OR label CONTAINS[c] 'all photos'")).firstMatch
            if allow.exists { allow.tap(); return true }
            print(alert.debugDescription)
            return false
        }
        app.launch()
        // A fresh simulator may present authorization after launch has returned.
        // Wait for the actual system button instead of tapping before the alert exists.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'full access' OR label CONTAINS[c] 'all photos'")).firstMatch
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        else { app.tap() }
        let firstPhoto = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-row-'")).firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 60), "Seed a local JPEG above 5 MB and grant Photos access")
        reviewedOriginalID = firstPhoto.identifier
        return app
    }

    private func openPhotoReview() -> XCUIApplication {
        let app = launchWithPhotoAccess()
        let firstPhoto = app.buttons[reviewedOriginalID]
        // The entire row, including empty space after the labels, must open preview.
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let compress = app.buttons["Compress"]
        XCTAssertTrue(compress.waitForExistence(timeout: 10))
        compress.tap()
        app.buttons["Higher quality"].tap()
        let keepBoth = app.buttons["Keep Both"]
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Delete Original"].exists)
        return app
    }

    func testPhotoReviewAndKeepBoth() {
        let app = openPhotoReview()
        app.buttons["Keep Both"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[reviewedOriginalID].exists)
    }

    func testDecliningDeletionKeepsOriginal() {
        let app = openPhotoReview()
        app.buttons["Delete Original"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Don't Allow", "Don’t Allow", "Cancel")).firstMatch
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        decline.tap()
        XCTAssertTrue(app.buttons["Keep Both"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons[reviewedOriginalID].waitForExistence(timeout: 10))
    }

    func testPrivacyAndTabs() {
        let app = XCUIApplication()
        app.launch()
        let privacy = app.buttons["Privacy & Support"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 20))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy & Support"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Videos"].tap()
        XCTAssertTrue(app.navigationBars["Videos"].exists)
        app.tabBars.buttons["Slim All"].tap()
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 5))
    }

    private func startSlim(_ app: XCUIApplication) {
        app.tabBars.buttons["Slim All"].tap()
        let scan = app.buttons["slim-get-started"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        let start = app.buttons["slim-start-run"]
        XCTAssertTrue(start.waitForExistence(timeout: 60))
        for _ in 0..<5 where !start.isHittable { app.swipeUp() }
        start.tap()
        app.alerts.buttons["Start"].tap()
    }

    private func declineSystemDeletion() {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = system.buttons.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Don't Allow", "Don’t Allow", "Cancel")).firstMatch
        XCTAssertTrue(decline.waitForExistence(timeout: 60))
        decline.tap()
    }

    func testSlimLowSpaceKeepsOriginals() {
        let app = launchWithPhotoAccess(arguments: ["-slimFakeFreeMB", "1"])
        startSlim(app)
        XCTAssertTrue(app.staticTexts["Running low on space"].waitForExistence(timeout: 20))
        app.buttons["Keep all remaining photos and end this run"].tap()
        XCTAssertTrue(app.staticTexts["All done"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Photos"].tap()
        XCTAssertTrue(app.buttons[reviewedOriginalID].waitForExistence(timeout: 10))
    }

    func testSlimRecoveryAfterDeclinedDeletion() {
        let app = launchWithPhotoAccess(arguments: ["-slimFlushSize", "1"])
        startSlim(app)
        declineSystemDeletion()
        XCTAssertTrue(app.staticTexts["Deletion cancelled"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        app.tabBars.buttons["Slim All"].tap()
        XCTAssertTrue(app.staticTexts["Unfinished run"].waitForExistence(timeout: 10))
        app.buttons["Undo the unfinished part"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let removeCopy = system.alerts.buttons["Delete"]
        XCTAssertTrue(removeCopy.waitForExistence(timeout: 30))
        removeCopy.tap()
        XCTAssertTrue(app.buttons["slim-get-started"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Photos"].tap()
        XCTAssertTrue(app.buttons[reviewedOriginalID].waitForExistence(timeout: 10))
    }

    func testSlimZAcceptDeletionOfDisposableOriginals() {
        let app = launchWithPhotoAccess(arguments: ["-slimFlushSize", "100"])
        startSlim(app)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let removeOriginals = system.alerts.buttons["Delete"]
        XCTAssertTrue(removeOriginals.waitForExistence(timeout: 120))
        removeOriginals.tap()
        XCTAssertTrue(app.staticTexts["All done"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Photos"].tap()
        XCTAssertTrue(app.buttons[reviewedOriginalID].waitForNonExistence(timeout: 20))
    }
}
