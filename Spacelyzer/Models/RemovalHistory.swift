import Foundation
import SwiftData

nonisolated enum UndoState: Int, Codable, Sendable {
    case undoable
    case undone
    /// Either it was permanent, or an attempt to bring it back could not finish.
    case unrestorable
}

/// One item within a removal batch, kept so it can be put back (FR-059).
@Model
final class RemovedItemRecord {
    var originalPath: String
    /// Nil for a permanent deletion, and the reason such a removal is honestly unrestorable.
    var trashPath: String?
    var size: Int64
    /// Ordering within the batch, since a relationship does not promise one.
    var position: Int

    init(originalPath: String, trashPath: String?, size: Int64, position: Int) {
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.position = position
    }
}

/// A completed removal, kept so the user can see what they have done and take back the last of it
/// (FR-061).
///
/// Only paths and sizes are stored. Nothing here records what was in a file, and clearing the
/// history leaves no trace of what was once on the disk.
@Model
final class RemovalHistoryEntry {
    var performedAt: Date
    var disposition: Disposition
    var bytesFreed: Int64
    var itemCount: Int
    var failureCount: Int
    var wasCancelled: Bool
    var undoState: UndoState
    /// Retained after a failed undo so the history can say why rather than merely that it failed.
    var undoBlockedReason: UndoBlocked?

    @Relationship(deleteRule: .cascade)
    var items: [RemovedItemRecord]

    init(
        performedAt: Date = .now,
        disposition: Disposition,
        bytesFreed: Int64,
        itemCount: Int,
        failureCount: Int,
        wasCancelled: Bool,
        undoState: UndoState,
        items: [RemovedItemRecord]
    ) {
        self.performedAt = performedAt
        self.disposition = disposition
        self.bytesFreed = bytesFreed
        self.itemCount = itemCount
        self.failureCount = failureCount
        self.wasCancelled = wasCancelled
        self.undoState = undoState
        self.items = items
    }

    /// The items in the order they were removed.
    var orderedItems: [RemovedItemRecord] {
        items.sorted { $0.position < $1.position }
    }
}

/// Reading and writing the history, so no view has to know about the store.
@MainActor
struct RemovalHistory {
    let context: ModelContext

    /// Newest first, which is the order anyone reads a history in.
    func all() -> [RemovalHistoryEntry] {
        let descriptor = FetchDescriptor<RemovalHistoryEntry>(
            sortBy: [SortDescriptor(\.performedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Only the latest batch can be taken back, which is what the spec asks for. Older removals
    /// stay recoverable by hand from the Trash.
    func mostRecent() -> RemovalHistoryEntry? {
        all().first
    }

    @discardableResult
    func record(_ summary: RemovalSummary) -> RemovalHistoryEntry {
        let items = summary.removed.enumerated().map { position, item in
            RemovedItemRecord(
                originalPath: item.originalPath,
                trashPath: item.trashPath,
                size: item.size,
                position: position
            )
        }
        let entry = RemovalHistoryEntry(
            disposition: summary.disposition,
            bytesFreed: summary.bytesFreed,
            itemCount: summary.removed.count,
            failureCount: summary.failures.count,
            wasCancelled: summary.wasCancelled,
            undoState: summary.disposition == .trash ? .undoable : .unrestorable,
            items: items
        )
        if summary.disposition == .deletedPermanently {
            entry.undoBlockedReason = .wasPermanent
        }
        context.insert(entry)
        try? context.save()
        return entry
    }

    func markUndone(_ entry: RemovalHistoryEntry, summary: UndoSummary) {
        // A partial restoration is not an undo. Saying it was would be the exact dishonesty
        // FR-060 forbids, so anything short of everything stays unrestorable with its reason.
        if summary.wasComplete {
            entry.undoState = .undone
            entry.undoBlockedReason = nil
        } else {
            entry.undoState = .unrestorable
            entry.undoBlockedReason = summary.failures.first?.reason ?? .failed
        }
        try? context.save()
    }

    func clear() {
        for entry in all() { context.delete(entry) }
        try? context.save()
    }
}
