import Foundation

/// Where a removed item goes. Trash unless the user says otherwise, in as many words (FR-053).
nonisolated enum Disposition: Int, Codable, Sendable {
    case trash
    case deletedPermanently

    var isRecoverable: Bool { self == .trash }
}

/// Why the guard will not remove something (FR-055).
///
/// Every case names a specific thing rather than a general refusal, because "cannot delete that"
/// tells the user nothing about what to do instead.
nonisolated enum RemovalRefusal: Int, Codable, Sendable, CaseIterable {
    case systemLocation
    case ownApplicationData
    case volumeRoot
    case homeDirectory
    case standardHomeFolder
    case insideTrash
    case noLongerThere

    var explanation: String {
        switch self {
        case .systemLocation:
            "The operating system owns this. Removing it would damage the installation."
        case .ownApplicationData:
            "This is Spacelyzer's own data, including the record of what you have removed."
        case .volumeRoot:
            "This is the whole volume. Erase it in Disk Utility if that is what you mean."
        case .homeDirectory:
            "This is your home folder. Choose something inside it instead."
        case .standardHomeFolder:
            "The system expects this folder to exist. Remove what is inside it instead."
        case .insideTrash:
            "This is already in the Trash. Empty the Trash to be rid of it."
        case .noLongerThere:
            "This is no longer at the location the analysis found it."
        }
    }
}

/// Why an individual removal did not happen, once one was actually attempted.
nonisolated enum RemovalFailure: Int, Codable, Sendable {
    case permissionDenied
    case noLongerThere
    case trashUnavailable
    case failed

    var explanation: String {
        switch self {
        case .permissionDenied: "You do not have permission to remove this."
        case .noLongerThere: "It was already gone."
        case .trashUnavailable: "This volume has no Trash."
        case .failed: "The system refused to remove it."
        }
    }
}

/// Why the most recent removal cannot be taken back (FR-060).
nonisolated enum UndoBlocked: Int, Codable, Sendable {
    case wasPermanent
    case trashEmptied
    case originalLocationMissing
    case somethingIsThereNow
    case failed

    var explanation: String {
        switch self {
        case .wasPermanent:
            "These were deleted permanently. There is nothing to bring back."
        case .trashEmptied:
            "The Trash no longer holds them."
        case .originalLocationMissing:
            "The folder they came from no longer exists."
        case .somethingIsThereNow:
            "Something else now occupies the place they came from."
        case .failed:
            "The system refused to move them back."
        }
    }
}

nonisolated enum UndoAvailability: Sendable, Equatable {
    case available
    case unavailable(UndoBlocked)

    var isAvailable: Bool { self == .available }
}

/// One item the guard is willing to remove, with the size it will reclaim.
nonisolated struct PlannedRemoval: Sendable, Equatable {
    let url: URL
    let size: Int64
}

nonisolated struct RefusedRemoval: Sendable, Equatable {
    let url: URL
    let refusal: RemovalRefusal
}

/// What would happen, worked out in full before anything is asked of the user (FR-052, FR-055).
///
/// A value. Producing one removes nothing, which is what lets the guard be tested exhaustively
/// against fixture trees rather than by watching what it destroys.
nonisolated struct RemovalPlan: Sendable, Equatable {
    let permitted: [PlannedRemoval]
    let refused: [RefusedRemoval]
    let trashAvailable: Bool

    static let empty = RemovalPlan(permitted: [], refused: [], trashAvailable: false)

    var totalReclaimable: Int64 { permitted.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { permitted.isEmpty }
    var hasRefusals: Bool { !refused.isEmpty }
}

/// One item that was actually removed, and where it went.
///
/// The Trash path is the only reliable handle for putting it back: the system renames on
/// collision, so the name it went in under is not something that can be worked out afterwards
/// (research R10).
nonisolated struct RemovedItem: Sendable, Equatable {
    let originalPath: String
    let trashPath: String?
    let size: Int64
}

nonisolated struct RemovalFailureRecord: Sendable, Equatable {
    let path: String
    let reason: RemovalFailure
}

/// What a finished batch actually did, as opposed to what was planned.
nonisolated struct RemovalSummary: Sendable, Equatable {
    let disposition: Disposition
    let removed: [RemovedItem]
    let failures: [RemovalFailureRecord]
    let wasCancelled: Bool

    var bytesFreed: Int64 { removed.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { removed.isEmpty && failures.isEmpty }
}

nonisolated enum RemovalEvent: Sendable {
    case removed(RemovedItem)
    case failed(RemovalFailureRecord)
    /// Always arrives, including after cancellation.
    case finished(RemovalSummary)
}

nonisolated struct RestoredItem: Sendable, Equatable {
    let path: String
}

nonisolated struct UndoFailureRecord: Sendable, Equatable {
    let path: String
    let reason: UndoBlocked
}

nonisolated struct UndoSummary: Sendable, Equatable {
    let restored: [RestoredItem]
    let failures: [UndoFailureRecord]

    /// Anything short of everything is a partial restoration, and saying otherwise is forbidden
    /// outright by FR-060.
    var wasComplete: Bool { failures.isEmpty && !restored.isEmpty }
}

nonisolated enum UndoEvent: Sendable {
    case restored(RestoredItem)
    case failed(UndoFailureRecord)
    case finished(UndoSummary)
}
