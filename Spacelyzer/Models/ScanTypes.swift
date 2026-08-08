import Foundation

nonisolated enum NodeKind: Int, Codable, Sendable {
    case file
    case directory
    /// An application bundle. Measured whole during the scan and only enumerated if the user
    /// asks to look inside it (FR-022).
    case package
    case symlink
    /// Synthesised during layout to stand for siblings too small to draw (FR-032). Has no
    /// filesystem counterpart.
    case remainder
}

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
