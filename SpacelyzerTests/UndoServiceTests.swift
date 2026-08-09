import Foundation
import Testing
@testable import Spacelyzer

/// Undo is the promise that makes removal safe to offer, so these cases care as much about the
/// times it cannot work as the times it can. Every fixture is the test's own, and anything left in
/// the Trash is taken back out at the end.
@Suite("Undo")
struct UndoServiceTests {

    private func trash(_ urls: [URL]) async -> RemovalSummary {
        let plan = RemovalGuard().evaluate(urls.map { RemovalCandidate(url: $0, size: 1_000) })
        var summary: RemovalSummary?
        for await event in RemovalService().perform(plan, disposition: .trash) {
            if case let .finished(result) = event { summary = result }
        }
        return summary
            ?? RemovalSummary(disposition: .trash, removed: [], failures: [], wasCancelled: false)
    }

    private func undo(_ items: [RemovedItem]) async -> UndoSummary {
        var summary: UndoSummary?
        for await event in UndoService().undo(items) {
            if case let .finished(result) = event { summary = result }
        }
        return summary ?? UndoSummary(restored: [], failures: [])
    }

    // MARK: - T098. Putting everything back

    @Test("Undo returns every item to where it came from")
    func undoRestoresEverything() async throws {
        let fixture = try FixtureTree()
        let one = try fixture.file("one.bin", contents: "first")
        let two = try fixture.file("nested/two.bin", contents: "second")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let removal = await trash([one, two])
        scrubber.track(removal)
        #expect(removal.removed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: one.path))

        let availability = UndoService().availability(of: removal.removed, disposition: .trash)
        #expect(availability == .available)

        let result = await undo(removal.removed)

        #expect(result.wasComplete)
        #expect(result.restored.count == 2)
        #expect(result.failures.isEmpty)

        // Back, and with what they contained. A restoration that returns an empty shell is not one.
        #expect(try String(contentsOf: one, encoding: .utf8) == "first")
        #expect(try String(contentsOf: two, encoding: .utf8) == "second")
    }

    @Test("A restored item is out of the Trash, not copied from it")
    func undoMovesRatherThanCopies() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("single.bin", contents: "content")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let removal = await trash([file])
        scrubber.track(removal)
        let trashPath = try #require(removal.removed.first?.trashPath)

        _ = await undo(removal.removed)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: trashPath))
    }

    // MARK: - T099. When it cannot work, saying so

    @Test("A permanent deletion is reported as unrestorable rather than attempted")
    func permanentIsUnrestorable() async throws {
        let items = [RemovedItem(originalPath: "/tmp/whatever.bin", trashPath: nil, size: 10)]

        #expect(
            UndoService().availability(of: items, disposition: .deletedPermanently)
                == .unavailable(.wasPermanent)
        )

        let result = await undo(items)
        #expect(!result.wasComplete)
        #expect(result.restored.isEmpty)
        #expect(result.failures.first?.reason == .wasPermanent)
    }

    @Test("An emptied Trash is reported as such, not as a failure to move")
    func emptiedTrashIsNamed() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("emptied.bin", contents: "gone")

        let removal = await trash([file])
        let trashPath = try #require(removal.removed.first?.trashPath)

        // Standing in for the user emptying the Trash between the removal and the undo.
        try FileManager.default.removeItem(atPath: trashPath)

        #expect(
            UndoService().availability(of: removal.removed, disposition: .trash)
                == .unavailable(.trashEmptied)
        )

        let result = await undo(removal.removed)
        #expect(!result.wasComplete)
        #expect(result.failures.first?.reason == .trashEmptied)
    }

    @Test("A folder that no longer exists is named as the reason")
    func missingOriginalLocationIsNamed() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("inside/deep.bin", contents: "content")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let removal = await trash([file])
        scrubber.track(removal)

        // The folder it came from goes too, so there is nowhere to put it back.
        try FileManager.default.removeItem(at: fixture.root.appending(path: "inside"))

        #expect(
            UndoService().availability(of: removal.removed, disposition: .trash)
                == .unavailable(.originalLocationMissing)
        )

        let result = await undo(removal.removed)
        #expect(!result.wasComplete)
        #expect(result.failures.first?.reason == .originalLocationMissing)
    }

    @Test("Something new in the old place is never written over")
    func occupiedLocationIsRefused() async throws {
        let fixture = try FixtureTree()
        let file = try fixture.file("contested.bin", contents: "original")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let removal = await trash([file])
        scrubber.track(removal)

        // Whatever is here now arrived after the removal, and quietly replacing it would be a
        // second deletion nobody asked for.
        try Data("newer".utf8).write(to: file)

        let result = await undo(removal.removed)
        #expect(!result.wasComplete)
        #expect(result.failures.first?.reason == .somethingIsThereNow)
        #expect(try String(contentsOf: file, encoding: .utf8) == "newer")
    }

    @Test("A partial restoration is never reported as a whole one")
    func partialIsNotSuccess() async throws {
        let fixture = try FixtureTree()
        let restorable = try fixture.file("restorable.bin", contents: "a")
        let blocked = try fixture.file("blocked.bin", contents: "b")
        var scrubber = TrashScrubber()
        defer { scrubber.scrub() }

        let removal = await trash([restorable, blocked])
        scrubber.track(removal)

        let blockedItem = try #require(
            removal.removed.first { $0.originalPath.hasSuffix("blocked.bin") }
        )
        try FileManager.default.removeItem(atPath: try #require(blockedItem.trashPath))

        let result = await undo(removal.removed)

        // One came back. That is not "undone", and FR-060 forbids calling it so.
        #expect(result.restored.count == 1)
        #expect(result.failures.count == 1)
        #expect(!result.wasComplete)
    }

    @Test("Every reason an undo can be blocked explains itself")
    func blockedReasonsAreExplained() {
        for reason in [
            UndoBlocked.wasPermanent, .trashEmptied, .originalLocationMissing, .somethingIsThereNow,
            .failed,
        ] {
            #expect(!reason.explanation.isEmpty)
        }
    }

    @Test("Nothing to undo is reported as unavailable rather than as an empty success")
    func nothingToUndoIsUnavailable() async {
        #expect(
            UndoService().availability(of: [], disposition: .trash) == .unavailable(.trashEmptied)
        )
        let result = await undo([])
        #expect(!result.wasComplete)
    }
}
