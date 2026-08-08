import Foundation
import SwiftData

nonisolated enum ScanState: Int, Codable, Sendable {
    case idle
    case requestingAccess
    case scanning
    case completed
    /// Stopped by the user. Partial results are retained and shown as incomplete (FR-004).
    case cancelled
    /// The result no longer reflects current settings, such as after the exclusion list changed
    /// (FR-013). Only a fresh scan leaves this state.
    case stale
    case failed

    var isFinished: Bool {
        switch self {
        case .completed, .cancelled, .stale, .failed: true
        case .idle, .requestingAccess, .scanning: false
        }
    }

    var resultsAreIncomplete: Bool {
        switch self {
        case .cancelled, .stale, .failed: true
        case .idle, .requestingAccess, .scanning, .completed: false
        }
    }
}

/// Why a location could not be read. Reported rather than silently dropped (FR-005).
nonisolated enum SkipReason: Int, Codable, Sendable {
    case permissionDenied
    case unreadable
    case volumeUnavailable
    case userExcluded

    var label: String {
        switch self {
        case .permissionDenied: "Permission denied"
        case .unreadable: "Could not be read"
        case .volumeUnavailable: "Volume unavailable"
        case .userExcluded: "Excluded by you"
        }
    }
}

@Model
final class SkippedLocation {
    var path: String
    var reason: SkipReason

    init(path: String, reason: SkipReason) {
        self.path = path
        self.reason = reason
    }
}

@Model
final class Scan {
    var rootPath: String
    var startedAt: Date
    var finishedAt: Date?
    var state: ScanState
    var measuredTotal: Int64

    @Relationship(deleteRule: .cascade)
    var root: ScanNode?

    @Relationship(deleteRule: .cascade)
    var skipped: [SkippedLocation]

    init(rootPath: String, startedAt: Date = .now, state: ScanState = .idle) {
        self.rootPath = rootPath
        self.startedAt = startedAt
        self.state = state
        self.measuredTotal = 0
        self.skipped = []
    }
}
