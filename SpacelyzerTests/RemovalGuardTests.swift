import Foundation
import Testing
@testable import Spacelyzer

/// Nothing in this suite removes anything. The guard is a value-returning function over paths, and
/// that is the point of it — the whole of Principle II's enforcement can be examined without
/// putting a single file at risk.
@Suite("Removal guard")
struct RemovalGuardTests {

    private func candidate(_ url: URL, size: Int64 = 1_000) -> RemovalCandidate {
        RemovalCandidate(url: url, size: size)
    }

    // MARK: - T093. What may never be removed

    @Test("The operating system's own locations are refused")
    func systemLocationsAreRefused() {
        let guardian = RemovalGuard()

        for path in ["/System", "/System/Library/CoreServices", "/bin", "/usr/bin/swift", "/dev"] {
            #expect(
                guardian.refusal(for: URL(fileURLWithPath: path)) == .systemLocation,
                "\(path) should be refused as a system location"
            )
        }
    }

    @Test("The app's own bundle and stored data are refused")
    func ownDataIsRefused() {
        let guardian = RemovalGuard()
        let home = NSHomeDirectory()
        let identifier = Bundle.main.bundleIdentifier ?? "co.lifehabitz.Spacelyzer"

        #expect(guardian.refusal(for: Bundle.main.bundleURL) == .ownApplicationData)

        // Refused whether or not it happens to exist on this machine: the removal history lives
        // here, and a batch that took it out would delete the record of itself.
        let support = URL(fileURLWithPath: "\(home)/Library/Application Support/\(identifier)")
        #expect(guardian.refusal(for: support) == .ownApplicationData)
        #expect(guardian.refusal(for: support.appending(path: "default.store")) == .ownApplicationData)
    }

    @Test("Roots, the home folder, and the folders the system expects are refused")
    func structuralLocationsAreRefused() {
        let guardian = RemovalGuard()
        let home = NSHomeDirectory()

        #expect(guardian.refusal(for: URL(fileURLWithPath: "/")) == .volumeRoot)
        #expect(guardian.refusal(for: URL(fileURLWithPath: "/Volumes/Whatever")) == .volumeRoot)
        #expect(guardian.refusal(for: URL(fileURLWithPath: home)) == .homeDirectory)
        #expect(guardian.refusal(for: URL(fileURLWithPath: "/Users")) == .homeDirectory)

        for name in ["Desktop", "Documents", "Downloads", "Library", "Pictures"] {
            #expect(
                guardian.refusal(for: URL(fileURLWithPath: "\(home)/\(name)")) == .standardHomeFolder,
                "\(name) should be kept even though its contents are fair game"
            )
        }
    }

    @Test("What is inside a protected folder is still removable")
    func contentsOfProtectedFoldersArePermitted() throws {
        // A cache under ~/Library is exactly what someone reclaiming space is after, so the folder
        // being protected must not protect everything in it.
        let fixture = try FixtureTree()
        let caches = try fixture.directory("Caches")
        let file = try fixture.file("Caches/something.bin", bytes: 500)
        let guardian = RemovalGuard(
            irremovableDirectories: [caches.standardizedFileURL.path]
        )

        #expect(guardian.refusal(for: caches) == .standardHomeFolder)
        #expect(guardian.refusal(for: file) == nil)
    }

    @Test("Something already in the Trash is refused rather than trashed again")
    func trashIsRefused() {
        let guardian = RemovalGuard()
        let path = NSHomeDirectory() + "/.Trash/whatever.bin"
        #expect(guardian.refusal(for: URL(fileURLWithPath: path)) == .insideTrash)
    }

    @Test("Something that has since gone is refused, not attempted")
    func missingIsRefused() throws {
        let fixture = try FixtureTree()
        let missing = fixture.root.appending(path: "never-existed.bin")
        #expect(RemovalGuard().refusal(for: missing) == .noLongerThere)
    }

    @Test("Every refusal explains itself")
    func refusalsAreExplained() {
        for refusal in RemovalRefusal.allCases {
            #expect(!refusal.explanation.isEmpty)
        }
    }

    // MARK: - T094. Planning is inert

    @Test("Producing a plan changes nothing on disk")
    func planningHasNoSideEffects() throws {
        let fixture = try FixtureTree()
        let keep = try fixture.file("keep.bin", contents: "still here")
        let doomed = try fixture.file("doomed.bin", contents: "also still here")
        try fixture.directory("folder")

        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()

        let plan = RemovalGuard().evaluate([
            candidate(keep), candidate(doomed), candidate(URL(fileURLWithPath: "/System")),
        ])

        #expect(plan.permitted.count == 2)
        #expect(plan.refused.count == 1)

        // The plan describes a removal. It has not performed one.
        let after = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        #expect(after == before)
        #expect(try String(contentsOf: doomed, encoding: .utf8) == "also still here")
    }

    // MARK: - T095. Refusing some permits the rest

    @Test("A refusal in the selection does not block the rest of it")
    func refusingSomeAllowsTheRest() throws {
        let fixture = try FixtureTree()
        let ordinary = try fixture.file("ordinary.bin", bytes: 2_000)

        let plan = RemovalGuard().evaluate([
            candidate(URL(fileURLWithPath: "/System"), size: 1),
            candidate(ordinary, size: 2_000),
            candidate(URL(fileURLWithPath: NSHomeDirectory()), size: 1),
        ])

        #expect(plan.permitted.map(\.url.lastPathComponent) == ["ordinary.bin"])
        #expect(plan.refused.count == 2)
        #expect(plan.totalReclaimable == 2_000)
        #expect(plan.hasRefusals)
        #expect(!plan.isEmpty)
    }

    @Test("The reclaimable total counts only what is actually permitted")
    func totalExcludesRefusals() throws {
        let fixture = try FixtureTree()
        let one = try fixture.file("one.bin", bytes: 100)
        let two = try fixture.file("two.bin", bytes: 100)

        let plan = RemovalGuard().evaluate([
            candidate(one, size: 1_000),
            candidate(two, size: 2_000),
            candidate(URL(fileURLWithPath: "/System"), size: 999_999),
        ])
        #expect(plan.totalReclaimable == 3_000)
    }

    @Test("An empty selection yields an empty plan that cannot claim a Trash")
    func emptySelectionIsSafe() {
        let plan = RemovalGuard().evaluate([])
        #expect(plan.isEmpty)
        #expect(!plan.trashAvailable)
        #expect(plan.totalReclaimable == 0)
    }
}
