import Foundation
import SwiftData

/// SwiftData holds the small, long-lived records only: exclusions, recent locations, removal
/// history, and preferences.
///
/// Scan results deliberately do not live here. Materialising one model object per file measured
/// between 4.7 and 15 times the cost of reading the entire filesystem tree, which is recorded in
/// research R5. Principle V permits the alternative precisely on that evidence. Results now live
/// as a value tree owned by the scan for the length of the session, which also keeps the promise
/// that no index of the user's disk is ever written to disk.
enum Storage {
    static let durableSchema = Schema([
        ExclusionRule.self,
        RecentLocation.self,
        Preferences.self,
        RemovalHistoryEntry.self,
        RemovedItemRecord.self,
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: durableSchema,
            configurations: ModelConfiguration(schema: durableSchema, isStoredInMemoryOnly: inMemory)
        )
    }
}
