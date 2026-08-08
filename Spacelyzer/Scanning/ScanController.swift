import Foundation
import SwiftData
import SwiftUI

/// Drives a scan and turns its value-typed result into `ScanNode` models.
///
/// The traversal itself runs off the main actor. Importing touches SwiftData, which is main-actor
/// bound here, so it yields between batches: a single blocking insert pass over a large tree
/// would freeze the interface that is meant to be showing progress (Principle III).
@MainActor
@Observable
final class ScanController {
    private(set) var state: ScanState = .idle
    private(set) var totals = ScanTotals()
    private(set) var currentPath: String = ""
    private(set) var rootNode: ScanNode?
    private(set) var skipped: [(path: String, reason: SkipReason)] = []
    private(set) var importedFraction: Double = 0

    let activity = ActivityIndicator()

    private var scanTask: Task<Void, Never>?
    private let engine = ScanEngine()

    var isRunning: Bool { state == .scanning }
    var resultsAreIncomplete: Bool { state.resultsAreIncomplete }

    func scan(root: URL, excluding exclusions: [URL] = [], into context: ModelContext) {
        cancel()

        state = .scanning
        totals = ScanTotals()
        skipped = []
        rootNode = nil
        importedFraction = 0
        activity.begin("Measuring \(root.lastPathComponent)")

        var options = ScanOptions()
        options.exclude(exclusions)

        scanTask = Task { [engine] in
            var finished: (root: ScannedItem, cancelled: Bool)?

            for await event in engine.scan(root: root, options: options) {
                switch event {
                case let .progress(totals, path):
                    self.totals = totals
                    self.currentPath = path
                case let .skipped(path, reason):
                    self.skipped.append((path, reason))
                case let .completed(item, totals):
                    self.totals = totals
                    finished = (item, false)
                case let .cancelled(item, totals):
                    self.totals = totals
                    finished = (item, true)
                }
            }

            guard let finished else {
                self.state = .idle
                self.activity.end()
                return
            }

            await self.importTree(finished.root, into: context)
            self.state = finished.cancelled ? .cancelled : .completed
            self.activity.end()
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if state == .scanning {
            state = .cancelled
            activity.end()
        }
    }

    /// Materialises models in batches, yielding so the interface keeps redrawing. This is the
    /// step most likely to miss the performance targets; research R5 records that risk.
    private func importTree(_ item: ScannedItem, into context: ModelContext) async {
        let total = max(1, item.itemCount)
        var created = 0
        var pending = 0

        func build(_ source: ScannedItem, parent: ScanNode?) async -> ScanNode {
            let node = ScanNode(
                name: source.name,
                kind: source.kind,
                category: source.category,
                ownSize: source.ownSize,
                cumulativeSize: source.cumulativeSize,
                itemCount: source.itemCount,
                created: source.created,
                modified: source.modified,
                accessed: source.accessed,
                countedElsewhere: source.countedElsewhere,
                unreadable: source.unreadable,
                hasUnexpandedContents: source.hasUnexpandedContents
            )
            node.parent = parent
            context.insert(node)

            created += 1
            pending += 1
            if pending >= 2_000 {
                pending = 0
                importedFraction = Double(created) / Double(total)
                await Task.yield()
            }

            for child in source.children {
                node.children.append(await build(child, parent: node))
            }
            return node
        }

        rootNode = await build(item, parent: nil)
        importedFraction = 1
    }
}
