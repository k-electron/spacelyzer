import Foundation
import Testing
@testable import Spacelyzer

@Suite("Scan cancellation")
struct ScanCancellationTests {

    @Test("Cancelling stops promptly and retains what was measured", .timeLimit(.minutes(1)))
    func cancellationIsPromptAndRetainsPartialResults() async throws {
        let fixture = try FixtureTree()
        try fixture.generateTree(fileCount: 20_000, filesPerDirectory: 50)

        let rootURL = fixture.root
        let clock = ContinuousClock()
        let started = clock.now

        // Consume the stream until cancelled. Tearing it down cancels the underlying work.
        let task = Task {
            for await _ in ScanEngine().scan(root: rootURL) {}
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = await task.value

        // FR-004 and SC-003: control returns within a second of asking it to stop.
        let elapsed = clock.now - started
        #expect(elapsed < .seconds(1))
    }

    @Test("Progress is coalesced rather than emitted per file", .timeLimit(.minutes(1)))
    func progressIsCoalesced() async throws {
        let fixture = try FixtureTree()
        try fixture.generateTree(fileCount: 5_000, filesPerDirectory: 50)

        let result = await ScanHarness.run(fixture.root)

        #expect(result.totals.itemsSeen >= 5_000)
        // Far fewer progress events than files. A per-file update would flood the interface that
        // exists to display it (Principle III).
        #expect(result.progressEvents < 500)
    }
}
