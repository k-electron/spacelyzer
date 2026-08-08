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

    func scan(root: URL, excluding exclusions: [URL] = [], in container: ModelContainer, context: ModelContext) {
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

            // Importing happens on a background context. Only the resulting identifier crosses
            // back, and the model is then resolved against the main context for display.
            self.importedFraction = 0.01
            let importer = ScanImporter(modelContainer: container)
            if let rootID = try? await importer.importTree(finished.root) {
                self.rootNode = context.model(for: rootID) as? ScanNode
            }
            self.importedFraction = 1

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

}
