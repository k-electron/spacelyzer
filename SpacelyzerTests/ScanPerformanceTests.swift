import Foundation
import SwiftData
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

        let container = try ModelContainer(
            for: Storage.scanSchema,
            configurations: ModelConfiguration(schema: Storage.scanSchema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let importTime = clock.measure {
            _ = insert(tree, parent: nil, into: context)
        }

        // The path the app actually takes: a background ModelActor, with only the parent side of
        // the relationship set.
        let actorContainer = try ModelContainer(
            for: Storage.scanSchema,
            configurations: ModelConfiguration(schema: Storage.scanSchema, isStoredInMemoryOnly: true)
        )
        let importer = ScanImporter(modelContainer: actorContainer)
        let backgroundImportStart = clock.now
        _ = try await importer.importTree(tree)
        let backgroundImportTime = clock.now - backgroundImportStart

        let report = """
            === SCAN PERFORMANCE (\(tree.itemCount) nodes) ===
            fixture build      : \(buildTime)
            traversal          : \(traversalTime)
            import (main-ish)  : \(importTime)
            import (ModelActor): \(backgroundImportTime)
            """
        // Written to a file because xcodebuild does not surface test stdout.
        try? Data(report.utf8).write(to: URL(fileURLWithPath: "/tmp/spacelyzer_perf.txt"))

        #expect(tree.itemCount >= fileCount)
    }

    @discardableResult
    private func insert(_ item: ScannedItem, parent: ScanNode?, into context: ModelContext) -> ScanNode {
        let node = ScanNode(
            name: item.name,
            kind: item.kind,
            category: item.category,
            ownSize: item.ownSize,
            cumulativeSize: item.cumulativeSize,
            itemCount: item.itemCount,
            created: item.created,
            modified: item.modified,
            accessed: item.accessed,
            countedElsewhere: item.countedElsewhere,
            unreadable: item.unreadable,
            hasUnexpandedContents: item.hasUnexpandedContents
        )
        node.parent = parent
        context.insert(node)
        for child in item.children {
            insert(child, parent: node, into: context)
        }
        return node
    }
}
