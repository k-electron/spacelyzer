import Foundation
import Testing
@testable import Spacelyzer

@Suite("Scan engine")
struct ScanEngineTests {

    @Test("Measures a known tree and reaches every file")
    func measuresKnownTree() async throws {
        let fixture = try FixtureTree()
        try fixture.file("top.bin", bytes: 40_000)
        try fixture.file("nested/inner.bin", bytes: 10_000)
        try fixture.directory("empty")

        let result = await ScanHarness.run(fixture.root)

        #expect(result.root.child(named: "top.bin") != nil)
        #expect(result.root.descendant("nested/inner.bin") != nil)
        #expect(result.root.child(named: "empty")?.children.isEmpty == true)
        // Allocated size rounds up to block boundaries, so assert the ordering relationship
        // rather than exact byte counts.
        #expect(result.totals.measuredBytes >= 50_000)
    }

    @Test("Reports both own and cumulative sizes for folders", .timeLimit(.minutes(1)))
    func reportsCumulativeSizes() async throws {
        let fixture = try FixtureTree()
        try fixture.file("branch/a.bin", bytes: 20_000)
        try fixture.file("branch/b.bin", bytes: 30_000)

        let result = await ScanHarness.run(fixture.root)
        let branch = try #require(result.root.child(named: "branch"))

        // A directory occupies no space itself; its cumulative size is everything beneath it.
        #expect(branch.ownSize == 0)
        #expect(branch.cumulativeSize >= 50_000)
        #expect(branch.cumulativeSize == branch.children.reduce(0) { $0 + $1.cumulativeSize })
        #expect(branch.itemCount == 3) // itself plus two files
    }

    @Test("Skips unreadable directories and reports them rather than aborting")
    func skipsUnreadableDirectories() async throws {
        let fixture = try FixtureTree()
        defer { fixture.restorePermissions() }
        try fixture.file("readable.bin", bytes: 15_000)
        try fixture.unreadableDirectory("locked")

        let result = await ScanHarness.run(fixture.root)

        // The readable portion is still measured.
        #expect(result.root.child(named: "readable.bin") != nil)
        #expect(result.totals.measuredBytes >= 15_000)
        // And the failure is surfaced with a reason rather than silently dropped.
        #expect(result.skipped.contains { $0.path.hasSuffix("locked") })
        #expect(result.skipped.first { $0.path.hasSuffix("locked") }?.reason == .permissionDenied)
    }

    @Test("Presents application bundles as single items")
    func packagesArriveWhole() async throws {
        let fixture = try FixtureTree()
        try fixture.appBundle("Demo.app", binaryBytes: 25_000)

        let result = await ScanHarness.run(fixture.root)
        let bundle = try #require(result.root.child(named: "Demo.app"))

        #expect(bundle.kind == .package)
        #expect(bundle.children.isEmpty)
        #expect(bundle.hasUnexpandedContents)
        // Measured whole even though its contents were not enumerated.
        #expect(bundle.cumulativeSize >= 25_000)
    }

    @Test("Expands a bundle on demand when the user asks to look inside")
    func expandsPackageOnDemand() async throws {
        let fixture = try FixtureTree()
        let bundleURL = try fixture.appBundle("Demo.app", binaryBytes: 25_000)
        let expanded = await ScanEngine().expandPackage(at: bundleURL)

        #expect(!expanded.children.isEmpty)
        #expect(expanded.descendant("Contents/MacOS/binary") != nil)
    }

    @Test("Excluded folders are reported as deliberate exclusions, not permission failures")
    func excludedFoldersReportedDistinctly() async throws {
        let fixture = try FixtureTree()
        try fixture.file("kept/a.bin", bytes: 10_000)
        try fixture.file("skipped/b.bin", bytes: 90_000)

        var options = ScanOptions()
        options.exclude([fixture.root.appending(path: "skipped", directoryHint: .isDirectory)])

        let result = await ScanHarness.run(fixture.root, options: options)

        #expect(result.skipped.contains { $0.reason == .userExcluded })
        #expect(result.root.child(named: "skipped")?.children.isEmpty == true)
        // The excluded subtree contributes nothing to the measured total.
        #expect(result.totals.measuredBytes < 90_000)
    }
}
