import XCTest

/// The treemap is the hardest case in this app for anyone not using their eyes, and the design
/// answer is that the outline is its complete equivalent while the drawn regions are exposed as
/// elements in their own right (research R7). Both halves of that claim are checked here.
final class AccessibilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// A fixed system folder keeps the test independent of whatever happens to be in the tester's
    /// home directory.
    private static let folder = "/System/Library/Fonts"

    @MainActor
    private func launchAndScanFonts() -> XCUIApplication {
        ScanFlow.launchAndScan(Self.folder)
    }

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
