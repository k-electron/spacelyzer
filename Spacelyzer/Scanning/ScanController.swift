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
    /// The location this result describes, kept so it can be rescanned or recorded as recent.
    private(set) var rootURL: URL?
    private(set) var skipped: [(path: String, reason: SkipReason)] = []
    /// How the measured total squares with what the volume reports (FR-014 through FR-017).
    /// Nil until a scan finishes, and on locations that report no volume at all.
    private(set) var accounting: VolumeAccounting?

    let activity = ActivityIndicator()
    /// Reconciliation has its own indicator because it outlives the scan: it shells out to
    /// `diskutil` twice, which takes long enough to owe the user a sign of life (Principle III).
    let accountingActivity = ActivityIndicator()

    private var scanTask: Task<Void, Never>?
    private var accountingTask: Task<Void, Never>?
    private let engine = ScanEngine()
    private let accountant = VolumeAccountant()

    var isRunning: Bool { state == .scanning }
    var resultsAreIncomplete: Bool { state.resultsAreIncomplete }

    func scan(root url: URL, excluding exclusions: [URL] = []) {
        cancel()

        state = .scanning
        totals = ScanTotals()
        skipped = []
        root = nil
        rootURL = url
        accounting = nil
        activity.begin("Analyzing \(url.lastPathComponent)")

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
            self.reconcile()
        }
    }

    /// Squares the measured total against the volume, off the main actor.
    ///
    /// Runs after a cancelled scan too. Partial results still sit on a real volume, and a total
    /// presented without the volume beside it is the misreading FR-015 exists to prevent.
    private func reconcile() {
        guard let url = rootURL, state == .completed || state == .cancelled else { return }

        let measured = totals.measuredBytes
        let skippedLocations = skipped
        accountingActivity.begin("Checking the totals")

        accountingTask = Task { [accountant] in
            let result = await Task.detached(priority: .utility) {
                accountant.account(
                    scanRoot: url,
                    measuredBytes: measured,
                    skipped: skippedLocations
                )
            }.value

            guard !Task.isCancelled else { return }
            self.accounting = result
            self.accountingActivity.end()
        }
    }

    /// Re-runs the current location, which is what makes a stale result actionable (FR-009).
    func rescan(excluding exclusions: [URL] = []) {
        guard let rootURL else { return }
        scan(root: rootURL, excluding: exclusions)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        accountingTask?.cancel()
        accountingTask = nil
        accountingActivity.end()
        if state == .scanning {
            state = .cancelled
            activity.end()
        }
    }
}
