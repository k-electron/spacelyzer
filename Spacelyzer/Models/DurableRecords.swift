import Foundation
import SwiftData
import SwiftUI

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

/// A folder the user has asked to be left out of scans, kept across sessions (FR-011).
@Model
final class ExclusionRule {
    /// Standardized on the way in, so a rule cannot be stored in a spelling that silently never
    /// matches the paths traversal produces.
    var path: String
    var createdAt: Date

    init(path: String, createdAt: Date = .now) {
        self.path = path
        self.createdAt = createdAt
    }
}

nonisolated enum AppearancePreference: Int, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Nil hands control back to the system rather than pinning either scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@Model
final class Preferences {
    var sizeUnitConvention: SizeUnitConvention
    var appearance: AppearancePreference

    init(sizeUnitConvention: SizeUnitConvention = .decimal, appearance: AppearancePreference = .system) {
        self.sizeUnitConvention = sizeUnitConvention
        self.appearance = appearance
    }

    /// There is exactly one preferences record. Fetching creates it on first launch rather than
    /// leaving every call site to cope with its absence.
    @MainActor
    static func current(in context: ModelContext) -> Preferences {
        if let existing = try? context.fetch(FetchDescriptor<Preferences>()).first {
            return existing
        }
        let created = Preferences()
        context.insert(created)
        try? context.save()
        return created
    }
}
