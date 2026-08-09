import Foundation
import SwiftData
import Testing
@testable import Spacelyzer

@MainActor
@Suite("Recent locations")
struct RecentLocationsTests {

    private func makeStore() throws -> RecentLocations {
        let container = try ModelContainer(
            for: Storage.durableSchema,
            configurations: ModelConfiguration(schema: Storage.durableSchema, isStoredInMemoryOnly: true)
        )
        return RecentLocations(context: ModelContext(container))
    }

    @Test("Scanning the same place twice keeps one entry, not two")
    func recordingIsIdempotent() throws {
        let fixture = try FixtureTree()
        let store = try makeStore()

        store.record(url: fixture.root, measuredTotal: 100)
        store.record(url: fixture.root, measuredTotal: 250)

        let all = store.all()
        #expect(all.count == 1)
        #expect(all.first?.lastMeasuredTotal == 250)
    }

    @Test("Most recently scanned comes first")
    func orderedByRecency() throws {
        let fixture = try FixtureTree()
        let first = try fixture.directory("one")
        let second = try fixture.directory("two")
        let store = try makeStore()

        store.record(url: first, measuredTotal: 1)
        store.record(url: second, measuredTotal: 2)

        #expect(store.all().first?.displayPath == second.standardizedFileURL.path)
    }

    @Test("History is capped so the start pane stays a launcher, not a log")
    func historyIsCapped() throws {
        let fixture = try FixtureTree()
        let store = try makeStore()

        for index in 0..<(RecentLocations.limit + 4) {
            let dir = try fixture.directory("d\(index)")
            store.record(url: dir, measuredTotal: Int64(index))
        }

        #expect(store.all().count == RecentLocations.limit)
    }

    @Test("A location that no longer exists reports unavailable rather than empty")
    func missingLocationIsUnavailable() throws {
        let fixture = try FixtureTree()
        let doomed = try fixture.directory("temporary")
        let store = try makeStore()

        store.record(url: doomed, measuredTotal: 42)
        try FileManager.default.removeItem(at: doomed)

        let entry = try #require(store.all().first)
        #expect(store.isAvailable(entry) == false)
        #expect(store.resolve(entry) == nil)
    }

    @Test("Forgetting a location removes it")
    func forgetRemoves() throws {
        let fixture = try FixtureTree()
        let store = try makeStore()
        store.record(url: fixture.root, measuredTotal: 10)

        let entry = try #require(store.all().first)
        store.forget(entry)

        #expect(store.all().isEmpty)
    }
}
