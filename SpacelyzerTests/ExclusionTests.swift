import Foundation
import SwiftData
import Testing
@testable import Spacelyzer

@MainActor
@Suite("Exclusions")
struct ExclusionTests {

    private func makeRules() throws -> ExclusionRules {
        let container = try ModelContainer(
            for: Storage.durableSchema,
            configurations: ModelConfiguration(schema: Storage.durableSchema, isStoredInMemoryOnly: true)
        )
        return ExclusionRules(context: ModelContext(container))
    }

    @Test("A folder you excluded is reported differently from one that could not be read")
    func exclusionIsDistinctFromDenial() async throws {
        let fixture = try FixtureTree()
        try fixture.file("kept/a.bin", bytes: 10_000)
        try fixture.file("excluded/b.bin", bytes: 90_000)
        let locked = try fixture.unreadableDirectory("locked")

        var options = ScanOptions()
        options.exclude([fixture.root.appending(path: "excluded", directoryHint: .isDirectory)])

        let result = await ScanHarness.run(fixture.root, options: options)

        // Two different causes, not one bucket of "missing". A folder the user chose to skip and
        // a folder the app was refused are different facts and lead to different remedies.
        let excluded = result.skipped.filter { $0.reason == .userExcluded }
        let denied = result.skipped.filter { $0.reason == .permissionDenied || $0.reason == .unreadable }

        #expect(excluded.count == 1)
        #expect(denied.count == 1)
        #expect(excluded.first?.path.hasSuffix("excluded") == true)
        #expect(denied.first?.path.hasSuffix("locked") == true)

        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    @Test("The accounting itemizes exclusions and denials as separate causes")
    func accountingKeepsThemApart() {
        let accountant = VolumeAccountant()
        let accounting = accountant.account(
            scanRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            measuredBytes: 1_000,
            skipped: [
                (path: "/tmp/excluded", reason: .userExcluded),
                (path: "/tmp/locked", reason: .permissionDenied),
                // Belongs to another volume's accounting, so it must not appear as a cause here.
                (path: "/Volumes/Other", reason: .separateVolume),
            ]
        )

        let causes = accounting?.itemization.map(\.cause) ?? []
        #expect(causes.contains(.userExcluded))
        #expect(causes.contains(.permissionDenied))
        #expect(causes.contains(.unattributed))
    }

    @Test("Excluding the folder being scanned is refused with a reason")
    func excludingTheRootIsRefused() throws {
        let fixture = try FixtureTree()
        let rules = try makeRules()

        // FR-012: not silently ignored. A refusal the user cannot see is a bug report waiting to
        // be filed against a feature that worked.
        #expect(throws: ExclusionRefusal.wouldExcludeScanRoot) {
            try rules.add(fixture.root, scanRoot: fixture.root)
        }
        #expect(ExclusionRefusal.wouldExcludeScanRoot.explanation.contains("nothing to look at"))
        #expect(rules.all().isEmpty)
    }

    @Test("A folder inside the scan root can be excluded")
    func excludingASubfolderIsAllowed() throws {
        let fixture = try FixtureTree()
        let inner = try fixture.directory("inner")
        let rules = try makeRules()

        try rules.add(inner, scanRoot: fixture.root)

        #expect(rules.all().count == 1)
        #expect(rules.excludedURLs().first?.standardizedFileURL == inner.standardizedFileURL)
    }

    @Test("The same folder cannot be excluded twice")
    func duplicateExclusionIsRefused() throws {
        let fixture = try FixtureTree()
        let inner = try fixture.directory("inner")
        let rules = try makeRules()

        try rules.add(inner, scanRoot: fixture.root)

        #expect(throws: ExclusionRefusal.alreadyExcluded) {
            try rules.add(inner, scanRoot: fixture.root)
        }
        #expect(rules.all().count == 1)
    }

    @Test("Changing the list marks a displayed result as no longer current")
    func changingTheListMakesResultsStale() throws {
        let fixture = try FixtureTree()
        let inner = try fixture.directory("inner")
        let rules = try makeRules()

        // FR-013: the result must not quietly change, and must not quietly stay either.
        #expect(rules.resultIsStale(scannedWith: []) == false)

        try rules.add(inner, scanRoot: fixture.root)
        #expect(rules.resultIsStale(scannedWith: []))
        #expect(rules.resultIsStale(scannedWith: [inner]) == false)
    }
}
