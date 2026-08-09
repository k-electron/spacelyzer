import Foundation
import Testing
@testable import Spacelyzer

/// A stand-in for a scanned item, for the cases that only exercise the filesystem side.
private func stub(_ name: String, kind: NodeKind = .file, bytes: Int64 = 0) -> ScannedItem {
    ScannedItem(
        name: name,
        kind: kind,
        category: kind == .directory ? .folder : .other,
        ownSize: bytes,
        cumulativeSize: bytes,
        itemCount: 1,
        created: .distantPast,
        modified: .distantPast,
        accessed: .distantPast,
        countedElsewhere: false,
        unreadable: false,
        hasUnexpandedContents: false,
        children: []
    )
}

@MainActor
@Suite("Inspecting an item")
struct ItemInspectorTests {

    /// Budgeted in polls rather than elapsed time, because other suites in this target hold the
    /// main actor for seconds at a stretch.
    private func waitForDetails(_ inspector: ItemInspector, polls: Int = 300) async throws {
        for _ in 0..<polls {
            if inspector.details != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The preview settles after the details, on purpose, so waiting for one is not waiting for
    /// the other.
    private func waitForPreview(_ inspector: ItemInspector, polls: Int = 300) async throws {
        for _ in 0..<polls {
            if inspector.preview != .loading, inspector.preview != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - T085. What the details report

    @Test("Details report the path, both sizes, the kind, and all three dates")
    func detailsDescribeTheItem() async throws {
        let fixture = try FixtureTree()
        let before = Date()
        try fixture.file("papers/report.txt", bytes: 5_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(
            path: rootPath + "/papers/report.txt", in: scan.root, rootPath: rootPath
        )
        try await waitForDetails(inspector)

        let details = try #require(inspector.details)
        #expect(details.path == rootPath + "/papers/report.txt")
        #expect(details.name == "report.txt")
        #expect(details.kind == .file)

        // Occupied comes from the scan and logical from the one read the inspector makes. They are
        // different questions, which is exactly why both are reported.
        #expect(details.occupiedBytes == scan.root.descendant("papers/report.txt")?.cumulativeSize)
        #expect(details.occupiedBytes > 0)
        #expect(details.logicalBytes == 5_000)

        #expect(!details.typeDescription.isEmpty)
        #expect(details.created >= before)
        #expect(details.modified >= before)
        #expect(details.accessed >= before)
    }

    @Test("A folder reports what its whole subtree occupies, and has no logical length")
    func folderDetailsCoverTheSubtree() async throws {
        let fixture = try FixtureTree()
        try fixture.file("papers/a.bin", bytes: 4_000)
        try fixture.file("papers/b.bin", bytes: 4_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath + "/papers", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)

        let details = try #require(inspector.details)
        let measured = try #require(scan.root.child(named: "papers"))
        #expect(details.kind == .directory)
        #expect(details.occupiedBytes == measured.cumulativeSize)
        #expect(details.occupiedBytes >= 8_000)
        // A folder has no single length, so there is nothing to set the occupied figure against.
        #expect(details.logicalBytes == nil)
        #expect(!details.sizesDiffer)
        #expect(details.itemCount == measured.itemCount)
    }

    @Test("Selecting the scan root itself is inspectable, not a dead end")
    func theRootIsInspectable() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", bytes: 2_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath, in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)

        #expect(inspector.details?.path == rootPath)
        #expect(inspector.details?.kind == .directory)
    }

    // MARK: - T086. When there is nothing to preview

    @Test("Every item without a preview is explained rather than failed")
    func unpreviewableItemsExplainThemselves() throws {
        let fixture = try FixtureTree()
        let folder = try fixture.directory("papers")
        let empty = try fixture.file("empty.txt", bytes: 0)
        let target = try fixture.file("target.txt", bytes: 100)
        let link = try fixture.symlink("link.txt", to: target)
        let gone = fixture.root.appending(path: "never-existed.txt")

        let cases: [(String, URL)] = [
            ("folder", folder), ("empty file", empty), ("symlink", link), ("missing file", gone),
        ]

        for (label, url) in cases {
            let state = ItemInspector.resolve(
                item: stub(url.lastPathComponent), at: url, path: url.path
            ).preview

            // Not an error and not a blank panel. Every one of these is a reason someone can act
            // on, which is the whole of FR-050.
            guard case .unavailable(let reason) = state else {
                Issue.record("\(label) should have no preview, got \(state)")
                continue
            }
            #expect(!reason.isEmpty, "\(label) gave no reason")
        }
    }

    @Test("A file that cannot be read says so rather than showing an empty preview")
    func unreadableFileExplainsItself() throws {
        let fixture = try FixtureTree()
        let locked = try fixture.file("locked.bin", bytes: 1_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path
            )
        }

        let state = ItemInspector.resolve(
            item: stub("locked.bin"), at: locked, path: locked.path
        ).preview

        guard case .unavailable(let reason) = state else {
            Issue.record("An unreadable file should have no preview, got \(state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("permission"))
    }

    @Test("A readable file with contents is offered to Quick Look")
    func ordinaryFileIsPreviewable() throws {
        let fixture = try FixtureTree()
        let url = try fixture.file("notes.txt", contents: "something to look at")

        let state = ItemInspector.resolve(item: stub("notes.txt"), at: url, path: url.path).preview
        #expect(state == .ready(url))
    }

    @Test("An application bundle previews, unlike an ordinary folder")
    func packagesArePreviewable() throws {
        let fixture = try FixtureTree()
        let bundle = try fixture.appBundle("Thing.app", binaryBytes: 500)

        // A package is a directory, but Quick Look has something real to say about one, so the
        // blanket refusal for folders must not catch it.
        let state = ItemInspector.resolve(
            item: stub("Thing.app", kind: .package), at: bundle, path: bundle.path
        ).preview
        #expect(state == .ready(bundle))
    }

    // MARK: - T087. Looking changes nothing

    @Test("Inspecting leaves the item's contents and location untouched")
    func inspectionChangesNothing() async throws {
        let fixture = try FixtureTree()
        try fixture.file("papers/report.txt", contents: "the original contents")
        try fixture.file("papers/other.bin", bytes: 300)

        let file = fixture.root.appending(path: "papers/report.txt")
        let folder = fixture.root.appending(path: "papers", directoryHint: .isDirectory)
        let manager = FileManager.default

        let contentsBefore = try Data(contentsOf: file)
        let attributesBefore = try manager.attributesOfItem(atPath: file.path)
        let listingBefore = try manager.contentsOfDirectory(atPath: folder.path).sorted()

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath + "/papers/report.txt", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)
        inspector.inspect(path: rootPath + "/papers", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)

        #expect(try Data(contentsOf: file) == contentsBefore)
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() == listingBefore)
        #expect(manager.fileExists(atPath: file.path))

        // Modification date, not access date. Reading a file is allowed to update when it was last
        // opened; that is the filesystem recording the look, not the app altering the file.
        let attributesAfter = try manager.attributesOfItem(atPath: file.path)
        #expect(
            attributesAfter[.modificationDate] as? Date == attributesBefore[.modificationDate] as? Date
        )
        #expect(attributesAfter[.size] as? Int == attributesBefore[.size] as? Int)
    }

    // MARK: - T090. Superseding and clearing

    @Test("A selection that moves on discards the answer for the one it left")
    func supersededInspectionIsDiscarded() async throws {
        let fixture = try FixtureTree()
        try fixture.file("first.bin", bytes: 1_000)
        try fixture.file("second.bin", bytes: 2_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath + "/first.bin", in: scan.root, rootPath: rootPath)
        inspector.inspect(path: rootPath + "/second.bin", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)

        // Long enough for a late answer about the first file to arrive, if one were coming.
        try await Task.sleep(for: .milliseconds(50))
        #expect(inspector.details?.name == "second.bin")
        #expect(inspector.url?.lastPathComponent == "second.bin")
    }

    @Test("Deselecting drops the details and stops reporting activity")
    func clearingReleasesEverything() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", bytes: 1_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath + "/a.bin", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)
        inspector.clear()

        #expect(inspector.details == nil)
        #expect(inspector.preview == nil)
        #expect(inspector.url == nil)
        #expect(!inspector.activity.isVisible)
    }

    @Test("A path that is not in the scan reports nothing rather than inventing an item")
    func unknownPathReportsNothing() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", bytes: 1_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: "/somewhere/else", in: scan.root, rootPath: rootPath)
        for _ in 0..<300 where inspector.preview != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inspector.details == nil)
        #expect(inspector.preview == nil)
    }

    @Test("Reselecting what is already being looked at does no work over again")
    func reselectingIsFree() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", bytes: 1_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        inspector.inspect(path: rootPath + "/a.bin", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)
        try await waitForPreview(inspector)

        // The second call must not put the panel back into loading. Both views re-emit the
        // selection they already hold, and a preview that restarts on each of those is a panel
        // that flickers for no reason.
        inspector.inspect(path: rootPath + "/a.bin", in: scan.root, rootPath: rootPath)
        #expect(inspector.preview == .ready(URL(fileURLWithPath: rootPath + "/a.bin")))
    }

    @Test("The preview waits for the selection to settle, but the details do not")
    func detailsArriveAheadOfThePreview() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", bytes: 1_000)
        try fixture.file("b.bin", bytes: 2_000)

        let rootPath = fixture.root.standardizedFileURL.path
        let scan = await ScanHarness.run(fixture.root)
        let inspector = ItemInspector()

        // Passing through on the way somewhere else, the way arrowing down a list does.
        inspector.inspect(path: rootPath + "/a.bin", in: scan.root, rootPath: rootPath)
        inspector.inspect(path: rootPath + "/b.bin", in: scan.root, rootPath: rootPath)
        try await waitForDetails(inspector)

        // Details describe the destination immediately. A preview of the file passed through must
        // never appear beside them.
        #expect(inspector.details?.name == "b.bin")
        #expect(inspector.preview != .ready(URL(fileURLWithPath: rootPath + "/a.bin")))

        try await waitForPreview(inspector)
        #expect(inspector.preview == .ready(URL(fileURLWithPath: rootPath + "/b.bin")))
    }

    @Test("A volume root, whose path already ends in a separator, still finds its children")
    func rootWithTrailingSeparatorResolves() {
        let tree = ScannedItem(
            name: "/", kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 10,
            itemCount: 2, created: .distantPast, modified: .distantPast, accessed: .distantPast,
            countedElsewhere: false, unreadable: false, hasUnexpandedContents: false,
            children: [stub("Users", kind: .directory, bytes: 10)]
        )

        // Both views join a parent path to a child name, which at a volume root produces a doubled
        // separator. The walk back down has to survive its own convention.
        #expect(ItemInspector.item(at: "//Users", in: tree, rootPath: "/")?.name == "Users")
        #expect(ItemInspector.item(at: "/", in: tree, rootPath: "/")?.name == "/")
        #expect(ItemInspector.item(at: "//Missing", in: tree, rootPath: "/") == nil)
    }
}
