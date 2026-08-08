import Foundation
@testable import Spacelyzer

/// Runs a scan to completion and collects everything it emitted.
struct ScanResult {
    var root: ScannedItem
    var totals: ScanTotals
    var skipped: [(path: String, reason: SkipReason)] = []
    var progressEvents: Int = 0
    var wasCancelled = false
}

enum ScanHarness {
    static func run(
        _ url: URL,
        options: ScanOptions = ScanOptions(),
        engine: ScanEngine = ScanEngine()
    ) async -> ScanResult {
        var result: ScanResult?
        var skipped: [(path: String, reason: SkipReason)] = []
        var progress = 0

        for await event in engine.scan(root: url, options: options) {
            switch event {
            case let .progress(totals, _):
                progress += 1
                _ = totals
            case let .skipped(path, reason):
                skipped.append((path, reason))
            case let .completed(root, totals):
                result = ScanResult(root: root, totals: totals)
            case let .cancelled(root, totals):
                var partial = ScanResult(root: root, totals: totals)
                partial.wasCancelled = true
                result = partial
            }
        }

        var final = result ?? ScanResult(
            root: ScannedItem(
                name: "", kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
                itemCount: 0, created: .distantPast, modified: .distantPast, accessed: .distantPast,
                countedElsewhere: false, unreadable: true, hasUnexpandedContents: false, children: []
            ),
            totals: ScanTotals()
        )
        final.skipped = skipped
        final.progressEvents = progress
        return final
    }
}

extension ScannedItem {
    func child(named name: String) -> ScannedItem? {
        children.first { $0.name == name }
    }

    func descendant(_ path: String) -> ScannedItem? {
        var current: ScannedItem? = self
        for component in path.split(separator: "/") {
            current = current?.child(named: String(component))
        }
        return current
    }

    var allDescendants: [ScannedItem] {
        children + children.flatMap(\.allDescendants)
    }
}
