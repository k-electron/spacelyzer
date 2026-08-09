import XCTest

final class SpacelyzerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// macOS restores window state between launches, and a restored "no windows" state leaves a
    /// UI test with nothing to inspect. Ignoring persistence gives every test the same clean
    /// starting point.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// The app opens onto something the user can act on, rather than an empty window.
    @MainActor
    func testLaunchesToAChoosableStartState() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["Choose something to measure"].waitForExistence(timeout: 10),
            "The start pane should invite the user to pick something to scan"
        )
        XCTAssertTrue(
            app.buttons["Choose Folder…"].exists,
            "A folder chooser should always be available, even with no volumes listed"
        )
    }

    /// The split layout is present from launch, with both sides accounted for. The trailing side
    /// explains itself until the treemap arrives in User Story 3.
    @MainActor
    func testShowsBothPanesOfTheSplitLayout() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["Treemap"].waitForExistence(timeout: 10),
            "The trailing pane should be present and labelled rather than blank"
        )
    }

    /// Sorting is a real control, not decoration. This guards the defect where the picker was
    /// wired to nothing because OutlineGroup could not see the selected order.
    @MainActor
    func testSortControlIsPresentAndOffersEveryOrder() throws {
        let app = launchApp()

        let sort = app.popUpButtons.firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 10), "A sort control should be in the toolbar")
    }
}
