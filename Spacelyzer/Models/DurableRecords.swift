import Foundation
import SwiftData

/// A folder the user has chosen to leave out of scanning (FR-010, FR-011).
@Model
final class ExclusionRule {
    var displayPath: String
    var createdAt: Date

    init(displayPath: String, createdAt: Date = .now) {
        self.displayPath = displayPath
        self.createdAt = createdAt
    }
}

/// A previously scanned root, so the user can return to it without navigating again (FR-009).
/// The bookmark survives the folder being renamed or moved.
@Model
final class RecentLocation {
    var displayPath: String
    var bookmark: Data?
    var lastScannedAt: Date
    var lastMeasuredTotal: Int64

    init(displayPath: String, bookmark: Data? = nil, lastScannedAt: Date = .now, lastMeasuredTotal: Int64 = 0) {
        self.displayPath = displayPath
        self.bookmark = bookmark
        self.lastScannedAt = lastScannedAt
        self.lastMeasuredTotal = lastMeasuredTotal
    }
}

@Model
final class Preferences {
    var sizeUnitConvention: SizeUnitConvention
    /// Files below this size are skipped by duplicate detection, since grouping them recovers
    /// negligible space for significant hashing cost. Adjustable down to zero.
    var duplicateMinimumFileSize: Int64

    init(sizeUnitConvention: SizeUnitConvention = .decimal, duplicateMinimumFileSize: Int64 = 1_000_000) {
        self.sizeUnitConvention = sizeUnitConvention
        self.duplicateMinimumFileSize = duplicateMinimumFileSize
    }
}
