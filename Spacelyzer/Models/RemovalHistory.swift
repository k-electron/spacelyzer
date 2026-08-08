import Foundation
import SwiftData

enum Disposition: Int, Codable, Sendable {
    case trashed
    case deletedPermanently
}

enum UndoState: Int, Codable, Sendable {
    case undoable
    case undone
    case unrestorable
}

enum RemovalOutcome: Int, Codable, Sendable {
    case removed
    case failed
    case refused
}

/// One item within a removal batch. `trashPath` is captured at removal time because the system
/// renames on collision, and it is the only reliable handle for restoring the item later.
@Model
final class RemovedItemRecord {
    var originalPath: String
    var trashPath: String?
    var size: Int64
    var outcome: RemovalOutcome

    init(originalPath: String, trashPath: String? = nil, size: Int64, outcome: RemovalOutcome) {
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.outcome = outcome
    }
}

@Model
final class RemovalHistoryEntry {
    var performedAt: Date
    var disposition: Disposition
    var spaceFreed: Int64
    var itemCount: Int
    var undoState: UndoState

    @Relationship(deleteRule: .cascade)
    var items: [RemovedItemRecord]

    init(
        performedAt: Date = .now,
        disposition: Disposition,
        spaceFreed: Int64 = 0,
        itemCount: Int = 0,
        undoState: UndoState = .undoable,
        items: [RemovedItemRecord] = []
    ) {
        self.performedAt = performedAt
        self.disposition = disposition
        self.spaceFreed = spaceFreed
        self.itemCount = itemCount
        self.undoState = undoState
        self.items = items
    }
}
