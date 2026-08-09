import XCTest

/// The treemap is the hardest case in this app for anyone not using their eyes, and the design
/// answer is that the outline is its complete equivalent while the drawn regions are exposed as
/// elements in their own right (research R7). Both halves of that claim are checked here.
final class AccessibilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func launchAndScanFonts() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["Choose Folder…"].waitForExistence(timeout: 20))
        app.buttons["Choose Folder…"].click()

        // Drive the open panel by keyboard: a fixed system folder keeps the test independent of
        // whatever happens to be in the tester's home directory. The panel does not expose its
        // buttons to the test runner, so these waits are on the clock; the one that matters is
        // the wait for the outline below, which is on the result actually arriving.
        Thread.sleep(forTimeInterval: 2)
        app.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        app.typeText(Self.folder)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        app.typeKey(.return, modifierFlags: [])

        let rootRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", Self.folder)
        ).firstMatch
        XCTAssertTrue(rootRow.waitForExistence(timeout: 60), "the scan should produce an outline")

        return app
    }

    private static let folder = "/System/Library/Fonts"

    /// Every outline row has to say what it is and how big it is, because that row is the whole
    /// of the accessible answer for anyone who cannot see the picture.
    ///
    /// A file row rather than a folder row on purpose: folder rows announced themselves correctly
    /// while leaf rows leaked their own truncated text instead, saying "Apple Color Emoji...."
    /// and no size at all.
    @MainActor
    func testFileRowsAnnounceNameAndSize() throws {
        let app = launchAndScanFonts()

        let described = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Apple Color Emoji.ttc", "of parent"
            )
        )
        XCTAssertGreaterThan(
            described.count, 0,
            "A file row should announce its name, size, and share rather than truncated text"
        )
    }

    /// The canvas is one drawing, so without this the treemap would be a single opaque element
    /// reporting nothing about what is in it.
    @MainActor
    func testTreemapExposesItsRegionsAsElements() throws {
        let app = launchAndScanFonts()

        let regions = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "of what is shown")
        )
        XCTAssertGreaterThan(
            regions.count, 0,
            "Drawn treemap regions should be reachable as elements, not hidden behind one canvas"
        )
    }
}
