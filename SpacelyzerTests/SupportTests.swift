import Foundation
import Testing
@testable import Spacelyzer

@Suite("Size formatting")
struct SizeFormatterTests {

    @Test("Decimal and binary conventions differ as expected")
    func conventionsDiffer() {
        let decimal = SizeFormatter(convention: .decimal).string(from: 1_000_000_000)
        let binary = SizeFormatter(convention: .binary).string(from: 1_000_000_000)
        #expect(decimal != binary)
        #expect(decimal.contains("GB"))
    }

    @Test("A zero total yields no share rather than dividing by zero")
    func zeroTotalHasNoShare() {
        let formatter = SizeFormatter()
        #expect(formatter.share(of: 0, in: 0) == nil)
        #expect(formatter.share(of: 50, in: 100) != nil)
    }
}

@Suite("Activity indication")
@MainActor
struct ActivityIndicatorTests {

    @Test("Fast work shows no indicator at all")
    func fastWorkShowsNothing() async throws {
        let indicator = ActivityIndicator(delay: .milliseconds(150))
        indicator.begin("scanning")
        try await Task.sleep(for: .milliseconds(20))
        indicator.end()
        try await Task.sleep(for: .milliseconds(200))

        // An indicator blinking on every fast operation tells the user less than none (FR-069).
        #expect(indicator.isVisible == false)
    }

    @Test("Work that outlives the delay becomes visible and clears afterwards")
    func slowWorkBecomesVisible() async throws {
        let indicator = ActivityIndicator(delay: .milliseconds(50))
        indicator.begin("scanning")
        try await Task.sleep(for: .milliseconds(200))
        #expect(indicator.isVisible == true)

        indicator.end()
        #expect(indicator.isVisible == false)
    }
}

@Suite("File categories")
struct FileCategoryTests {

    @Test("Directories classify as folders regardless of type")
    func directoriesAreFolders() {
        #expect(FileCategory.classify(nil, isDirectory: true) == .folder)
    }

    @Test("An unknown type falls back to other rather than guessing")
    func unknownFallsBack() {
        #expect(FileCategory.classify(nil, isDirectory: false) == .other)
    }
}
