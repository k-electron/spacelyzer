import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Spacelyzer

@MainActor
@Suite("Preferences")
struct PreferencesTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Storage.durableSchema,
            configurations: ModelConfiguration(schema: Storage.durableSchema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("There is exactly one preferences record, created on demand")
    func singleRecord() throws {
        let context = try makeContext()

        let first = Preferences.current(in: context)
        first.appearance = .dark
        let second = Preferences.current(in: context)

        #expect(second.appearance == .dark)
        #expect(try context.fetch(FetchDescriptor<Preferences>()).count == 1)
    }

    @Test("Appearance defaults to following the system")
    func defaultsToSystem() throws {
        let context = try makeContext()
        #expect(Preferences.current(in: context).appearance == .system)
    }

    @Test("Only the system setting defers to the system; light and dark pin the scheme")
    func colorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test("Every appearance option is offered, so dark is never a one-way door")
    func everyOptionIsSelectable() {
        let options = AppearancePreference.allCases
        #expect(options.count == 3)
        #expect(options.contains(.light))
        #expect(options.allSatisfy { !$0.label.isEmpty && !$0.symbol.isEmpty })
    }

    @Test("The duplicate threshold survives a round trip and can be turned off")
    func duplicateThresholdIsAdjustable() throws {
        let context = try makeContext()

        #expect(Preferences.current(in: context).duplicateSizeThreshold == 1_000_000)

        Preferences.current(in: context).duplicateSizeThreshold = 0
        #expect(Preferences.current(in: context).duplicateSizeThreshold == 0)
    }
}

@MainActor
@Suite("Opening the store")
struct StorageTests {

    @Test("A store that will not open costs the records, not the app")
    func aBadStoreFallsBackToMemory() throws {
        struct Unopenable: Error {}

        let opened = Storage.open(openDurable: { throw Unopenable() })

        // The whole point of T132: this used to be `fatalError`, so a store that would not open
        // was an app that would not launch, permanently, over records that no part of measuring
        // a disk needs.
        let warning = try #require(opened.warning, "a session that keeps nothing must say so")
        #expect(warning.contains("cannot be saved"))

        // And the fallback is a working container, not a placeholder — scanning, removing, and
        // undoing all still have somewhere to put their state for the session.
        let context = ModelContext(opened.container)
        let preferences = Preferences.current(in: context)
        preferences.duplicateSizeThreshold = 42
        #expect(Preferences.current(in: context).duplicateSizeThreshold == 42)
    }

    @Test("A store that opens says nothing")
    func aGoodStoreIsQuiet() throws {
        let opened = Storage.open(openDurable: { try Storage.makeContainer(inMemory: true) })
        #expect(opened.warning == nil)
    }
}
