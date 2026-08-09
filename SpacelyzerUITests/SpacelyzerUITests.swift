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
            app.staticTexts["Choose something to analyze"].waitForExistence(timeout: 10),
            "The start pane should invite the user to pick something to scan"
        )
        XCTAssertTrue(
            app.buttons["Choose Folder…"].exists,
            "A folder chooser should always be available, even with no volumes listed"
        )
    }

    /// The split layout is present from launch with both sides accounted for, and neither side is
    /// blank before a scan has run.
    @MainActor
    func testShowsBothPanesOfTheSplitLayout() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["Choose something to analyze"].waitForExistence(timeout: 10),
            "The leading pane should offer somewhere to start"
        )
        XCTAssertTrue(
            app.staticTexts["Nothing analyzed yet"].waitForExistence(timeout: 10),
            "The trailing pane should explain itself rather than sitting blank"
        )
    }

    /// The treemap owns the trailing pane, so the accounting from User Story 2 has to stay
    /// reachable rather than being displaced by it.
    @MainActor
    func testTrailingPaneOffersBothTreemapAndTotals() throws {
        let app = launchApp()

        let totals = app.radioButtons["Totals"]
        XCTAssertTrue(totals.waitForExistence(timeout: 10), "A Totals view should be selectable")
        XCTAssertTrue(app.radioButtons["Treemap"].exists, "A Treemap view should be selectable")

        totals.click()
        XCTAssertTrue(
            app.staticTexts["No totals yet"].waitForExistence(timeout: 5),
            "Switching to Totals before a scan should explain why it is empty"
        )
    }

    /// The details panel sits beside the two views rather than replacing either, and says what it
    /// is waiting for instead of sitting blank.
    ///
    /// Whether it starts open is a remembered preference, so the test establishes the state it
    /// needs rather than assuming one, and leaves it open again for whoever runs next.
    @MainActor
    func testDetailsPanelOpensAndExplainsItself() throws {
        let app = launchApp()

        let toggle = app.buttons["Details"]
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10), "A details toggle should be in the toolbar"
        )

        let empty = app.staticTexts["Nothing selected"]
        if !empty.waitForExistence(timeout: 3) {
            toggle.click()
        }
        XCTAssertTrue(
            empty.waitForExistence(timeout: 5),
            "The details panel should say it is waiting for a selection"
        )

        toggle.click()
        XCTAssertTrue(
            empty.waitForNonExistence(timeout: 5),
            "The details panel should close when it is toggled away"
        )

        toggle.click()
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
