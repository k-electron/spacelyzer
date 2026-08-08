import Foundation
import Testing
@testable import Spacelyzer

@Suite("Byte accounting")
struct ByteAccountingTests {

    @Test("Hard-linked data is counted once but appears at every path")
    func hardLinkCountedOnce() async throws {
        let fixture = try FixtureTree()
        let original = try fixture.file("original.bin", bytes: 60_000)
        try fixture.hardLink("elsewhere/copy.bin", to: original)

        let result = await ScanHarness.run(fixture.root)

        // Both names exist in the tree, because the user has two paths to the same data.
        #expect(result.root.child(named: "original.bin") != nil)
        #expect(result.root.descendant("elsewhere/copy.bin") != nil)

        // But the bytes are counted exactly once, so the total is not inflated (FR-006).
        #expect(result.totals.measuredBytes < 120_000)
        #expect(result.totals.measuredBytes >= 60_000)

        let counted = result.root.allDescendants.filter { !$0.countedElsewhere && $0.ownSize > 0 }
        #expect(counted.count == 1)
    }

    @Test("A symlink pointing at an ancestor neither loops nor inflates totals")
    func symlinkToAncestorIsSafe() async throws {
        let fixture = try FixtureTree()
        try fixture.file("real.bin", bytes: 30_000)
        try fixture.directory("branch")
        try fixture.symlink("branch/loop", to: fixture.root)

        let result = await ScanHarness.run(fixture.root)

        let link = try #require(result.root.descendant("branch/loop"))
        #expect(link.kind == .symlink)
        // Never followed, so it has no children and contributes no size (FR-007).
        #expect(link.children.isEmpty)
        #expect(link.cumulativeSize == 0)
        #expect(result.totals.measuredBytes < 60_000)
    }

    @Test("A symlink to a file is recorded without counting the target's bytes again")
    func symlinkToFileNotDoubleCounted() async throws {
        let fixture = try FixtureTree()
        let target = try fixture.file("target.bin", bytes: 50_000)
        try fixture.symlink("alias", to: target)

        let result = await ScanHarness.run(fixture.root)

        #expect(result.root.child(named: "alias")?.kind == .symlink)
        #expect(result.root.child(named: "alias")?.ownSize == 0)
        #expect(result.totals.measuredBytes < 100_000)
    }
}
