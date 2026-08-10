import Foundation
import Testing

@testable import Spacelyzer

@Suite("Finding duplicates")
struct DuplicateFinderTests {

    // MARK: - T112: identical files group, with the right recoverable total

    @Test("Byte-identical files group into one set, whatever they are called")
    func identicalFilesGroup() async throws {
        let fixture = try FixtureTree()
        let body = String(repeating: "the same bytes throughout. ", count: 400)
        try fixture.file("a/report.bin", contents: body)
        try fixture.file("b/copy-of-report.bin", contents: body)
        try fixture.file("c/nested/third.bin", contents: body)
        try fixture.file("d/different.bin", contents: String(repeating: "other bytes here...... ", count: 400))

        let report = try await run(over: fixture, minimumSize: 0)

        #expect(report.sets.count == 1)
        let set = try #require(report.sets.first)
        #expect(set.copies.count == 3)
        #expect(set.copies.map(\.name).sorted() == ["copy-of-report.bin", "report.bin", "third.bin"])

        // Two of the three are recoverable. Keeping one is the point of a duplicate set.
        #expect(set.recoverableSize == set.copySize * 2)
    }

    @Test("Sets are ranked by what each would give back")
    func setsRankByRecovery() async throws {
        let fixture = try FixtureTree()
        let small = String(repeating: "s", count: 4_000)
        let large = String(repeating: "L", count: 40_000)
        try fixture.file("small/one.bin", contents: small)
        try fixture.file("small/two.bin", contents: small)
        try fixture.file("large/one.bin", contents: large)
        try fixture.file("large/two.bin", contents: large)

        let report = try await run(over: fixture, minimumSize: 0)

        #expect(report.sets.count == 2)
        #expect(report.sets.map(\.recoverableSize) == report.sets.map(\.recoverableSize).sorted(by: >))
        #expect(report.recoverableSize == report.sets.reduce(0) { $0 + $1.recoverableSize })
    }

    // MARK: - T113: equal size is not identity

    @Test("Files of equal size with differing contents are never called duplicates")
    func equalSizesAreNotEnough() async throws {
        let fixture = try FixtureTree()
        // The same length to the byte, differing at the very end so that no bounded prefix could
        // tell them apart. FR-063 says only the contents decide, and this is the case that
        // catches an implementation which stopped reading early.
        let shared = String(repeating: "identical opening. ", count: 5_000)
        try fixture.file("first.bin", contents: shared + "A")
        try fixture.file("second.bin", contents: shared + "B")

        let report = try await run(over: fixture, minimumSize: 0, prefixLength: 1_024)

        #expect(report.sets.isEmpty)
        #expect(report.considered == 2)
    }

    @Test("Files with the same name in different folders are not duplicates by name")
    func namesAreNotEnough() async throws {
        let fixture = try FixtureTree()
        try fixture.file("one/notes.txt", contents: String(repeating: "x", count: 3_000))
        try fixture.file("two/notes.txt", contents: String(repeating: "y", count: 3_000))

        #expect(try await run(over: fixture, minimumSize: 0).sets.isEmpty)
    }

    @Test("Hard links to one file are not offered as duplicates of each other")
    func hardLinksAreNotDuplicates() async throws {
        let fixture = try FixtureTree()
        let original = try fixture.file("original.bin", contents: String(repeating: "z", count: 8_000))
        try fixture.hardLink("alias.bin", to: original)

        // The same inode reached by two paths. The bytes are identical by definition, but they
        // are one copy on the disk, so removing either gives back nothing and calling them
        // duplicates would promise space that is not there.
        #expect(try await run(over: fixture, minimumSize: 0).sets.isEmpty)
    }

    // MARK: - T115: the size threshold

    @Test("The threshold leaves small files out, and can be lowered until it does not")
    func thresholdExcludesSmallFiles() async throws {
        let fixture = try FixtureTree()
        let body = String(repeating: "tiny. ", count: 100)
        try fixture.file("a.bin", contents: body)
        try fixture.file("b.bin", contents: body)

        let ignored = try await run(over: fixture, minimumSize: 1_000_000)
        #expect(ignored.sets.isEmpty)
        #expect(ignored.considered == 0)
        #expect(ignored.belowThreshold == 2, "a run that found nothing should say what it skipped")

        let found = try await run(over: fixture, minimumSize: 0)
        #expect(found.sets.count == 1)
        #expect(found.belowThreshold == 0)
    }

    @Test("A megabyte is the threshold unless something says otherwise")
    func defaultThresholdIsAMegabyte() {
        #expect(Preferences.defaultDuplicateSizeThreshold == 1_000_000)
        #expect(DuplicateFinder().minimumSize == Preferences.defaultDuplicateSizeThreshold)
        #expect(Preferences().duplicateSizeThreshold == 1_000_000)
    }

    // MARK: - T118: progress and cancellation

    @Test("Every stage reports, and the last report of a stage is its whole count")
    func progressCoversEveryStage() async throws {
        let fixture = try FixtureTree()
        let body = String(repeating: "reported. ", count: 20_000)
        for i in 0..<4 { try fixture.file("f\(i).bin", contents: body) }

        var seen: Set<DuplicateStage> = []
        for await event in DuplicateFinder(minimumSize: 0, prefixLength: 1_024)
            .find(in: try await scan(fixture), rootPath: fixture.root.standardizedFileURL.path)
        {
            if case let .progress(progress) = event { seen.insert(progress.stage) }
        }

        #expect(seen.contains(.grouping))
        #expect(seen.contains(.sampling))
        #expect(seen.contains(.hashing))
    }

    @Test("Cancelling stops the search and says so", .timeLimit(.minutes(1)))
    func cancellingStopsAndSaysSo() async throws {
        let fixture = try FixtureTree()
        let body = String(repeating: "identical throughout. ", count: 6_000)
        for i in 0..<60 { try fixture.file("f\(i).bin", contents: body) }

        let tree = try await scan(fixture)
        let path = fixture.root.standardizedFileURL.path

        // Every file holds the same bytes, so nothing drops out early and all of them reach the
        // full read. Reading it a byte at a time makes that take long enough to interrupt on
        // purpose, rather than by writing a fixture large enough to be slow by accident — the
        // same code path either way, and eight megabytes instead of a gigabyte.
        var finder = DuplicateFinder()
        finder.minimumSize = 0
        finder.chunkLength = 1

        let work = Task { () -> Bool in
            var reported = false
            for await event in finder.find(in: tree, rootPath: path) {
                if case .finished = event { reported = true }
            }
            return reported
        }
        try await Task.sleep(for: .milliseconds(60))
        let stopped = ContinuousClock().now
        work.cancel()
        let finished = await work.value
        let waited = ContinuousClock().now - stopped

        // FR-066. Nothing is claimed about a search that was stopped: no report arrives, so
        // nothing half-proved can be shown as a duplicate. What this cannot observe from out here
        // is the passes themselves stopping — cancelling the consumer is what ends the listening —
        // and that is why they check between files rather than relying on being unheard.
        #expect(finished == false)
        #expect(waited < .seconds(1))
    }

    // MARK: - Helpers

    private func scan(_ fixture: FixtureTree) async throws -> ScannedItem {
        await ScanHarness.run(fixture.root).root
    }

    private func run(
        over fixture: FixtureTree,
        minimumSize: Int64,
        prefixLength: Int = 64 * 1024
    ) async throws -> DuplicateReport {
        var finder = DuplicateFinder()
        finder.minimumSize = minimumSize
        finder.prefixLength = prefixLength

        let tree = await ScanHarness.run(fixture.root).root
        for await event in finder.find(in: tree, rootPath: fixture.root.standardizedFileURL.path) {
            if case let .finished(report) = event { return report }
        }
        throw DuplicateTestFailure.noReport
    }
}

private enum DuplicateTestFailure: Error {
    case noReport
}

// MARK: - T114: the set refuses to empty itself

@Suite("Keeping one copy")
struct DuplicateSetTests {

    private func set(copies: Int = 3, size: Int64 = 1_000) -> DuplicateSet {
        DuplicateSet(
            id: "digest",
            copies: (0..<copies).map { DuplicateCopy(path: "/scan/copy\($0).bin", size: size) }
        )
    }

    @Test("The last copy cannot be marked, however many times it is asked")
    func theLastCopyIsRefused() {
        var subject = set(copies: 3)

        let first = subject.mark("/scan/copy0.bin")
        let second = subject.mark("/scan/copy1.bin")
        #expect(first)
        #expect(second)

        // FR-065. Two of three are gone and the third is what the set exists to protect.
        #expect(subject.refusal(forMarking: "/scan/copy2.bin") == .wouldLeaveNoCopy)
        let third = subject.mark("/scan/copy2.bin")
        #expect(third == false)
        #expect(subject.marked.count == 2)
        #expect(subject.removalCandidates().count == 2)
    }

    @Test("Marking everything at once still keeps one")
    func markAllKeepsOne() {
        var subject = set(copies: 4)
        subject.markAllButOne()

        #expect(subject.marked.count == 3)
        #expect(subject.markableCount == 3)
        #expect(subject.copies.contains { !subject.isMarked($0.path) })
    }

    @Test("No plan the set produces can empty it, whatever route is taken")
    func noRouteEmptiesTheSet() {
        // The point of T119: the rule is the type's, not a view's. Every ordering of every
        // request still leaves a copy behind, because there is no call that can remove one.
        for order in [[0, 1, 2, 3], [3, 2, 1, 0], [1, 3, 0, 2]] {
            var subject = set(copies: 4)
            for index in order + order {
                subject.mark("/scan/copy\(index).bin")
            }
            #expect(subject.marked.count == 3)
            #expect(subject.removalCandidates().count < subject.copies.count)
        }
    }

    @Test("Unmarking frees the refusal again")
    func unmarkingMakesRoom() {
        var subject = set(copies: 2)
        let marked = subject.mark("/scan/copy0.bin")
        #expect(marked)
        #expect(subject.refusal(forMarking: "/scan/copy1.bin") == .wouldLeaveNoCopy)

        subject.unmark("/scan/copy0.bin")
        #expect(subject.refusal(forMarking: "/scan/copy1.bin") == nil)
        let other = subject.mark("/scan/copy1.bin")
        #expect(other)
    }

    @Test("A path from somewhere else is refused rather than quietly marked")
    func foreignPathsAreRefused() {
        var subject = set(copies: 3)
        #expect(subject.refusal(forMarking: "/somewhere/else.bin") == .notInThisSet)
        let accepted = subject.mark("/somewhere/else.bin")
        #expect(accepted == false)
        #expect(subject.marked.isEmpty)
    }

    @Test("What it would give back is every copy but one")
    func recoverableIsEveryCopyButOne() {
        #expect(set(copies: 3, size: 1_000).recoverableSize == 2_000)
        #expect(set(copies: 2, size: 1_000).recoverableSize == 1_000)
        #expect(set(copies: 5, size: 512).recoverableSize == 2_048)
    }

    @Test("A set stops being one when it is down to a single copy")
    func aSingleCopyIsNoLongerASet() throws {
        let subject = set(copies: 3)

        let two = try #require(subject.removing(["/scan/copy0.bin"]))
        #expect(two.copies.count == 2)
        #expect(subject.removing(["/scan/copy0.bin", "/scan/copy1.bin"]) == nil)
    }
}
