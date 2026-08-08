import Foundation
import SwiftData

/// Two configurations in one container.
///
/// Scan results are in-memory only. SwiftData persists by default, so without this a complete
/// index of the user's disk would be written to Application Support and picked up by Time
/// Machine. Making it in-memory is what enforces the promise that no scan outlives the session,
/// rather than merely intending it.
enum Storage {
    static let scanSchema = Schema([ScanNode.self, Scan.self, SkippedLocation.self])

    static let durableSchema = Schema([
        ExclusionRule.self,
        RecentLocation.self,
        Preferences.self,
        RemovalHistoryEntry.self,
        RemovedItemRecord.self,
    ])

    /// Every model type across both configurations. The container needs one combined schema; the
    /// configurations then each claim their own subset of it.
    static let fullSchema = Schema([
        ScanNode.self,
        Scan.self,
        SkippedLocation.self,
        ExclusionRule.self,
        RecentLocation.self,
        Preferences.self,
        RemovalHistoryEntry.self,
        RemovedItemRecord.self,
    ])

    static func makeContainer(inMemoryDurableStore: Bool = false) throws -> ModelContainer {
        let scan = ModelConfiguration(
            "Scan",
            schema: scanSchema,
            isStoredInMemoryOnly: true
        )
        let durable = ModelConfiguration(
            "Durable",
            schema: durableSchema,
            isStoredInMemoryOnly: inMemoryDurableStore
        )
        return try ModelContainer(for: fullSchema, configurations: scan, durable)
    }
}
