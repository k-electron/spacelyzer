import Foundation
import Testing
@testable import Spacelyzer

/// Separates where the time actually goes: walking the filesystem, versus turning the result into
/// SwiftData models. Guessing at this was what research R5 warned about.
@Suite("Scan performance breakdown", .serialized)
struct ScanPerformanceTests {

    @Test("Traversal and import timings", .timeLimit(.minutes(5)))
    @MainActor
    func breakdown() async throws {
        let fileCount = 50_000
        let fixture = try FixtureTree()
        let clock = ContinuousClock()

        let buildTime = try clock.measure {
            try fixture.generateTree(fileCount: fileCount, filesPerDirectory: 100)
        }

        let rootURL = fixture.root
        var scanned: ScannedItem?
        let traversalTime = await clock.measure {
            let result = await ScanHarness.run(rootURL)
            scanned = result.root
        }
        let tree = try #require(scanned)

        let report = """
            === SCAN PERFORMANCE (\(tree.itemCount) nodes) ===
            fixture build : \(buildTime)
            traversal     : \(traversalTime)
            """
        // Written to a file because xcodebuild does not surface test stdout.
        try? Data(report.utf8).write(to: URL(fileURLWithPath: "/tmp/spacelyzer_perf.txt"))

        #expect(tree.itemCount >= fileCount)
    }

}
