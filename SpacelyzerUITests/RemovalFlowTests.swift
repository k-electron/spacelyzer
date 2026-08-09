import XCTest

/// The one test in the suite that drives a real deletion, so it is built to be incapable of
/// touching anything but its own fixture.
///
/// Four things enforce that, in order. The fixture folder is created by this test under a name
/// carrying a fresh UUID, and the file inside it carries the same, so nothing else on the machine
/// can answer to either. The scan is confirmed to have found that file before anything is
/// selected. `continueAfterFailure` is off, so a failed check stops the run rather than carrying
/// on to the destructive button. And the confirmation is read before it is agreed to — the test
/// asserts it names exactly one item and that the item is its own, so an app that ever proposed
/// something else would fail this rather than delete it.
final class RemovalFlowTests: XCTestCase {

    /// Off deliberately. Every check before the confirmation is a safety check, and carrying on
    /// past a failed one is precisely what must not happen here.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var fixture: URL?
    private var filename = ""

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        purgeFromTrash()
    }

    /// Anything a run that did not finish left in the Trash. Matched on the fixture's unique name,
    /// so nothing this test did not create can be caught by it.
    private func purgeFromTrash() {
        guard !filename.isEmpty else { return }
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".Trash")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        for entry in contents where entry.hasPrefix(filename) {
            try? FileManager.default.removeItem(at: trash.appending(path: entry))
        }
    }

    /// A folder of this test's own, named so that nothing else can match it.
    private func makeFixture(_ label: String) throws -> URL {
        let token = String(UUID().uuidString.prefix(8))
        filename = "spacelyzer-uitest-\(token).bin"

        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = caches.appending(path: "\(label)-\(token)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = folder

        try Data(repeating: 0x51, count: 64_000).write(to: folder.appending(path: filename))
        // A second file, so a batch that took the whole folder would look different from one that
        // took what was asked for.
        try Data(repeating: 0x52, count: 1_000).write(to: folder.appending(path: "bystander.bin"))
        return folder
    }

    private func firstMatch(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
    }

    @MainActor
    func testRemoveThenPutBack() throws {
        let folder = try makeFixture("SpacelyzerRemovalFixture")
        let target = folder.appending(path: filename)
        let bystander = folder.appending(path: "bystander.bin")

        // Waiting on the unique filename is the proof that the right folder was analysed: no other
        // folder on the machine holds a file by this name.
        let app = ScanFlow.launchAndScan(folder.path, expecting: filename)

        let row = firstMatch(app, containing: filename)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()

        // MARK: Read the confirmation before agreeing to it

        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        XCTAssertTrue(
            app.staticTexts["Remove 1 item?"].waitForExistence(timeout: 5),
            "Refusing to go on: the confirmation should name exactly one item"
        )
        XCTAssertTrue(
            firstMatch(app, containing: filename).exists,
            "Refusing to go on: the confirmation does not name this test's file"
        )

        let confirm = app.buttons["Move to Trash"]
        XCTAssertTrue(confirm.exists, "Trash should be the offered disposition, not deletion")
        confirm.click()

        // MARK: It went, and only it

        let putBack = app.buttons["Put Back"]
        XCTAssertTrue(putBack.waitForExistence(timeout: 20), "A summary with an undo should appear")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path), "The file should have moved"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bystander.path),
            "Nothing beyond the selection should have been touched"
        )

        // MARK: And came back

        putBack.click()
        XCTAssertTrue(
            app.staticTexts["Everything was put back."].waitForExistence(timeout: 20),
            "Undo should report what it did"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "The file should be back")
        XCTAssertEqual(
            try Data(contentsOf: target).count, 64_000, "It should come back with its contents"
        )

        app.buttons["Done"].click()
    }

    /// Backing out of the confirmation has to be a real way out, not a pause before the same
    /// outcome.
    @MainActor
    func testCancellingTheConfirmationRemovesNothing() throws {
        let folder = try makeFixture("SpacelyzerCancelFixture")
        let target = folder.appending(path: filename)

        let app = ScanFlow.launchAndScan(folder.path, expecting: filename)

        let row = firstMatch(app, containing: filename)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()

        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        XCTAssertTrue(app.staticTexts["Remove 1 item?"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()

        // Long enough that a removal begun in the background would have happened by now.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path),
            "Cancelling must leave everything exactly as it was"
        )
        XCTAssertEqual(try Data(contentsOf: target).count, 64_000)
    }
}
