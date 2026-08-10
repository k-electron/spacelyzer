import XCTest

/// Driving the duplicates view for real: analyse a folder, search it, and read what comes back.
///
/// Nothing here removes anything. The removal path out of this view is the same batch machinery
/// `RemovalFlowTests` already drives end to end, and this test's value is in what the search finds
/// and what the set refuses — neither of which needs a file to be deleted to check.
final class DuplicatesFlowTests: XCTestCase {

    private var fixture: URL?
    private var token = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    /// Three identical files under different names in different folders, and a fourth of exactly
    /// the same size holding something else — which is the case FR-063 exists for.
    ///
    /// Each is comfortably over the default megabyte threshold, so the search can run without the
    /// test having to reach into a menu to lower it.
    private func makeFixture() throws -> URL {
        token = String(UUID().uuidString.prefix(8))

        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = caches.appending(
            path: "SpacelyzerDuplicates-\(token)", directoryHint: .isDirectory
        )
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = folder

        let shared = Data(repeating: 0x41, count: 1_500_000)
        for (index, name) in ["alpha", "beta", "gamma"].enumerated() {
            let sub = folder.appending(path: "folder\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try shared.write(to: sub.appending(path: "\(name)-\(token).bin"))
        }

        // The same length to the byte, different contents. A search that grouped this with the
        // others would be reporting size as identity, which is exactly what FR-063 forbids.
        var impostor = Data(repeating: 0x41, count: 1_499_999)
        impostor.append(0x42)
        try impostor.write(to: folder.appending(path: "impostor-\(token).bin"))

        return folder
    }

    private func firstMatch(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
    }

    @MainActor
    func testFindingDuplicatesGroupsIdenticalFilesOnly() throws {
        let folder = try makeFixture()
        let app = ScanFlow.launchAndScan(folder.path, expecting: "alpha-\(token).bin")

        // A segment of the pane's picker, which the runner exposes as a radio button rather than
        // as a plain one.
        let tab = app.radioButtons["Duplicates"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the pane should offer a duplicates view")
        tab.click()

        let search = app.buttons["Find Duplicates"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the view should offer a search")
        search.click()

        // Three of the four files are identical, so exactly one set of three copies.
        let set = firstMatch(app, containing: "3 copies")
        XCTAssertTrue(
            set.waitForExistence(timeout: 60), "three identical files should group as one set"
        )

        // And the fourth is not in it. Same size, different bytes, so it is nobody's duplicate.
        XCTAssertFalse(
            firstMatch(app, containing: "4 copies").exists,
            "a file of matching size but differing contents must not join the set"
        )
    }

    @MainActor
    func testTheLastCopyCannotBeTicked() throws {
        let folder = try makeFixture()
        let app = ScanFlow.launchAndScan(folder.path, expecting: "alpha-\(token).bin")

        let tab = app.radioButtons["Duplicates"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()

        let search = app.buttons["Find Duplicates"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()

        let set = firstMatch(app, containing: "3 copies")
        XCTAssertTrue(set.waitForExistence(timeout: 60))

        // The triangle, not the row. A disclosure group's label is a label; clicking it selects
        // the row without opening anything.
        let triangle = app.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 10), "a set should open to its copies")
        triangle.click()

        let copies = app.checkBoxes
        XCTAssertTrue(
            copies.firstMatch.waitForExistence(timeout: 10), "an opened set should show its copies"
        )
        XCTAssertEqual(copies.count, 3, "each copy in the set should be tickable")

        copies.element(boundBy: 0).click()
        copies.element(boundBy: 1).click()

        // The third is refused, which is FR-065 reaching the interface. The set is what enforces
        // it; this checks the window says so rather than offering a tick that would be ignored.
        XCTAssertTrue(
            app.buttons["Remove 2"].waitForExistence(timeout: 10),
            "two of three copies should be offered for removal"
        )
        XCTAssertFalse(
            copies.element(boundBy: 2).isEnabled,
            "the copy that has to stay must not be tickable"
        )
        // Matched on value rather than label: a bare `Text` inside a row arrives with its string
        // there and nothing in its label at all.
        let kept = app.staticTexts.matching(NSPredicate(format: "value == %@", "kept")).firstMatch
        XCTAssertTrue(kept.exists, "and it should say why it is staying")
        XCTAssertFalse(app.buttons["Remove 3"].exists, "all three must never be offered")
    }
}
