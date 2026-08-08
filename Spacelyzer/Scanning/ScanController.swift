import Foundation
import SwiftUI

/// Drives a scan and holds its result.
///
/// The result is the value tree the engine produced, used directly by the interface. An earlier
/// version materialised one SwiftData model per file, which measured between 4.7 and 15 times the
/// cost of the traversal itself and was the reason a large scan felt frozen. Research R5 records
/// the measurement.
@MainActor
@Observable
final class ScanController {
    private(set) var state: ScanState = .idle
    private(set) var totals = ScanTotals()
    private(set) var currentPath: String = ""
    private(set) var root: ScannedItem?
    private(set) var skipped: [(path: String, reason: SkipReason)] = []

    let activity = ActivityIndicator()

    private var scanTask: Task<Void, Never>?
    private let engine = ScanEngine()

    var isRunning: Bool { state == .scanning }
    var resultsAreIncomplete: Bool { state.resultsAreIncomplete }

    func scan(root url: URL, excluding exclusions: [URL] = []) {
        cancel()

        state = .scanning
        totals = ScanTotals()
        skipped = []
        root = nil
        activity.begin("Measuring \(url.lastPathComponent)")

        var options = ScanOptions()
        options.exclude(exclusions)

        scanTask = Task { [engine] in
            for await event in engine.scan(root: url, options: options) {
                switch event {
                case let .progress(totals, path):
                    self.totals = totals
                    self.currentPath = path
                case let .skipped(path, reason):
                    self.skipped.append((path, reason))
                case let .completed(item, totals):
                    self.totals = totals
                    self.root = item
                    self.state = .completed
                case let .cancelled(item, totals):
                    self.totals = totals
                    self.root = item
                    self.state = .cancelled
                }
            }
            if self.state == .scanning { self.state = .idle }
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
