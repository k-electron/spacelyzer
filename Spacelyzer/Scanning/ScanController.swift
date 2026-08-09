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
    /// Subtrees taken out by a removal, held in case it is undone.
    private var forgotten: [(path: String, item: ScannedItem)] = []
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

    /// Takes removed items out of the result and settles the sizes above them (FR-057).
    ///
    /// A rescan would give the same answer and cost a walk of the whole disk to do it. The tree is
    /// a value, so the cheap thing is to build the version of it that no longer contains what was
    /// just removed, and hand that to the views.
    func forget(paths: [String]) {
        guard !paths.isEmpty, let root, let rootURL else { return }

        let removed = Set(paths)
        let rootPath = rootURL.standardizedFileURL.path

        // Kept so an undo can put them back where they were. Rescanning to recover sizes the app
        // already knew would cost a walk of the whole disk to learn nothing new.
        for path in paths {
            if let item = ItemInspector.item(at: path, in: root, rootPath: rootPath) {
                forgotten.append((path: path, item: item))
            }
        }

        // The root itself going means there is no result left to show rather than an empty one.
        guard !removed.contains(rootPath) else {
            self.root = nil
            totals = ScanTotals()
            return
        }

        guard let pruned = Self.pruning(root, at: rootPath, removing: removed) else { return }
        self.root = pruned
        totals = ScanTotals(measuredBytes: pruned.cumulativeSize, itemsSeen: pruned.itemCount)
    }

    /// Puts back what `forget` took out, for the items an undo actually restored (FR-057).
    func remember(paths: [String]) {
        guard !paths.isEmpty, let root, let rootURL else { return }

        let wanted = Set(paths)
        let returning = forgotten.filter { wanted.contains($0.path) }
        guard !returning.isEmpty else { return }

        let rootPath = rootURL.standardizedFileURL.path
        var tree = root
        for entry in returning {
            tree =
                Self.grafting(tree, at: rootPath, inserting: entry.item, at: entry.path) ?? tree
        }

        self.root = tree
        forgotten.removeAll { wanted.contains($0.path) }
        totals = ScanTotals(measuredBytes: tree.cumulativeSize, itemsSeen: tree.itemCount)
    }

    /// Reinserts a subtree at the path it came from, settling totals back up the chain.
    ///
    /// Returns nil when the way down no longer exists, which happens if a parent folder was
    /// removed in a later batch. The item is genuinely back on disk in that case; it simply has no
    /// place in this result, and the honest answer is to leave the result alone.
    nonisolated static func grafting(
        _ item: ScannedItem,
        at path: String,
        inserting child: ScannedItem,
        at target: String
    ) -> ScannedItem? {
        let prefix = path + "/"
        guard target.hasPrefix(prefix) else { return nil }

        var kept = item
        let remainder = target.dropFirst(prefix.count)

        if let separator = remainder.firstIndex(of: "/") {
            let nextName = String(remainder[remainder.startIndex..<separator])
            guard
                let index = kept.children.firstIndex(where: { $0.name == nextName }),
                let updated = Self.grafting(
                    kept.children[index], at: prefix + nextName, inserting: child, at: target
                )
            else { return nil }
            kept.children[index] = updated
        } else {
            // Already there, so a second undo of the same batch changes nothing.
            guard !kept.children.contains(where: { $0.name == String(remainder) }) else {
                return item
            }
            kept.children.append(child)
        }

        kept.cumulativeSize = kept.ownSize + kept.children.reduce(0) { $0 + $1.cumulativeSize }
        kept.itemCount = 1 + kept.children.reduce(0) { $0 + $1.itemCount }
        return kept
    }

    /// Rebuilds only the path down to what was removed, settling each folder's totals on the way
    /// back up so no ancestor keeps claiming space that is no longer there.
    ///
    /// A subtree with nothing going in it is returned exactly as it stands. Rebuilding the whole
    /// tree to delete one file would allocate a million nodes to change a handful of them, on the
    /// main actor, immediately after the user pressed a button.
    nonisolated static func pruning(
        _ item: ScannedItem,
        at path: String,
        removing: Set<String>
    ) -> ScannedItem? {
        if removing.contains(path) { return nil }

        let prefix = path + "/"
        guard removing.contains(where: { $0.hasPrefix(prefix) }) else { return item }

        var kept = item
        kept.children = item.children.compactMap {
            pruning($0, at: prefix + $0.name, removing: removing)
        }
        kept.cumulativeSize = kept.ownSize + kept.children.reduce(0) { $0 + $1.cumulativeSize }
        kept.itemCount = 1 + kept.children.reduce(0) { $0 + $1.itemCount }
        return kept
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
