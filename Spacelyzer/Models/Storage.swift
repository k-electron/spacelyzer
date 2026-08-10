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
    /// Only what is actually in use. Each model arrived with the story that needed it, rather than
    /// sitting in the schema of a live on-disk store waiting to be migrated.
    static let durableSchema = Schema([
        RecentLocation.self,
        ExclusionRule.self,
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

    /// A container to start with, and whether anything will actually be kept.
    ///
    /// Opening the store used to be `try` or `fatalError`, which made a store that would not open
    /// an app that would not launch — permanently, since nothing about launching fixes it. None of
    /// what it holds is needed to measure a disk: the exclusions, the recent locations, the
    /// preferences, and the removal history are all conveniences around the job.
    ///
    /// So a failure falls back to memory, and says so. Falling back quietly would be worse than
    /// the crash: the history view would show an empty history and forget again on quit, which is
    /// not the record of removals Principle II promises. The window carries `warning` where the
    /// user can see it.
    /// `openDurable` exists so the failing path can be tested. The only other way to reach it is
    /// to corrupt a real store on a real machine, which is not something a test may do.
    static func open(
        openDurable: () throws -> ModelContainer = { try makeContainer() }
    ) -> (container: ModelContainer, warning: String?) {
        do {
            return (try openDurable(), nil)
        } catch {
            guard let fallback = try? makeContainer(inMemory: true) else {
                // Memory refused as well, which is not a broken store but a broken world. There
                // is nothing left to fall back to.
                fatalError("Could not create a model container in memory: \(error)")
            }
            return (
                fallback,
                "Settings, recent locations, and removal history cannot be saved this session, "
                    + "because their store would not open. Analysing and removing still work, but "
                    + "nothing will be remembered after Spacelyzer quits."
            )
        }
    }
}
