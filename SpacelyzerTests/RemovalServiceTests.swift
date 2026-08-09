import Foundation
import Testing
@testable import Spacelyzer

/// These move real files to the real Trash, because that is the thing under test and a fake Trash
/// would only test the fake. Every file involved is one the test created under the system
/// temporary directory, and whatever reaches the Trash is taken back out at the end of each case.
@Suite("Removal service")
struct RemovalServiceTests {

    private func run(
        _ plan: RemovalPlan,
        disposition: Disposition = .trash,
        service: RemovalService = RemovalService()
    ) async -> (removed: [RemovedItem], failed: [RemovalFailureRecord], summary: RemovalSummary) {
        var removed: [RemovedItem] = []
        var failed: [RemovalFailureRecord] = []
        var summary: RemovalSummary?

        for await event in service.perform(plan, disposition: disposition) {
            switch event {
            case let .removed(item): removed.append(item)
            case let .failed(record): failed.append(record)
            case let .finished(result): summary = result
            }
        }

        return (
            removed, failed,
            summary
                ?? RemovalSummary(
                    disposition: disposition, removed: [], failures: [], wasCancelled: false
                )
        )
    }

    private func plan(_ urls: [URL], sizes: Int64 = 1_000) -> RemovalPlan {
        RemovalGuard().evaluate(urls.map { RemovalCandidate(url: $0, size: sizes) })
    }

    // MARK: - T096. To the Trash, with the way back recorded

    @Test("Removal puts items in the Trash and records where each one landed")
    func removalTrashesAndCapturesTheReturnPath() async throws {
        let fixture = try FixtureTree()
        let one = try fixture.file("one.bin", contents: "first")
        let two = try fixture.file("two.bin", contents: "second")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let result = await run(plan([one, two]))
        scrubber.track(result.summary)

        #expect(result.removed.count == 2)
        #expect(result.failed.isEmpty)
        #expect(!result.summary.wasCancelled)

        // Gone from where they were.
        #expect(!FileManager.default.fileExists(atPath: one.path))
        #expect(!FileManager.default.fileExists(atPath: two.path))

        // And findable where they went. This path is the whole basis of undo, so an item recorded
        // without one is an item that cannot come back.
        for item in result.removed {
            let trashPath = try #require(item.trashPath, "\(item.originalPath) recorded no Trash path")
            #expect(TrashScrubber.isInsideTrash(trashPath))
            #expect(FileManager.default.fileExists(atPath: trashPath))
        }
    }

    @Test("The summary totals what was actually freed")
    func summaryTotalsWhatWasFreed() async throws {
        let fixture = try FixtureTree()
        let one = try fixture.file("one.bin", bytes: 4_000)
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let result = await run(plan([one], sizes: 4_000))
        scrubber.track(result.summary)

        #expect(result.summary.bytesFreed == 4_000)
        #expect(result.summary.disposition == .trash)
    }

    // MARK: - T097. One failure does not end the batch

    @Test("An item that fails is reported and the rest still go")
    func oneFailureDoesNotAbortTheBatch() async throws {
        let fixture = try FixtureTree()
        let first = try fixture.file("first.bin", contents: "a")
        let vanishing = try fixture.file("vanishing.bin", contents: "b")
        let last = try fixture.file("last.bin", contents: "c")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let prepared = plan([first, vanishing, last])
        #expect(prepared.permitted.count == 3)

        // Removed behind the plan's back, the way a file being deleted in another window would be.
        try FileManager.default.removeItem(at: vanishing)

        let result = await run(prepared)
        scrubber.track(result.summary)

        #expect(result.removed.count == 2)
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.reason == .noLongerThere)
        #expect(result.failed.first?.path.hasSuffix("vanishing.bin") == true)

        // The summary carries both halves, so nothing is quietly dropped.
        #expect(result.summary.removed.count == 2)
        #expect(result.summary.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: last.path))
    }

    @Test("Every failure explains itself")
    func failuresAreExplained() {
        for reason in [
            RemovalFailure.permissionDenied, .noLongerThere, .trashUnavailable, .failed,
        ] {
            #expect(!reason.explanation.isEmpty)
        }
    }

    // MARK: - The guard cannot be walked around

    @Test("A plan naming something protected removes nothing, however it was built")
    func aForgedPlanIsStillRefused() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("protected.bin", contents: "untouched")

        // The plan is assembled by hand, as a value, with no guard involved — which is exactly
        // what a future caller could do by accident. The service looks again on its own account.
        let forged = RemovalPlan(
            permitted: [PlannedRemoval(url: file, size: 1_000)],
            refused: [],
            trashAvailable: true
        )
        let service = RemovalService(guardian: RemovalGuard(systemRoots: [fixture.root.path]))

        let result = await run(forged, service: service)

        #expect(result.removed.isEmpty)
        #expect(result.failed.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "untouched")
    }

    @Test("An empty plan finishes cleanly rather than hanging")
    func emptyPlanFinishes() async {
        let result = await run(RemovalPlan.empty)
        #expect(result.summary.isEmpty)
        #expect(!result.summary.wasCancelled)
    }

    // MARK: - Permanent deletion

    @Test("Permanent deletion leaves nothing to come back to, and says so")
    func permanentDeletionRecordsNoReturnPath() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("gone.bin", contents: "for good")

        let result = await run(plan([file]), disposition: .deletedPermanently)

        #expect(result.removed.count == 1)
        #expect(result.removed.first?.trashPath == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(result.summary.disposition == .deletedPermanently)
    }
}
