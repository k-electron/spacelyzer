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
}
