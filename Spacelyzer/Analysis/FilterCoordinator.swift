import Foundation
import SwiftUI

/// Holds the active filter and the one result both views read.
///
/// Evaluation runs off the main actor: the function is pure but not cheap, and calling it while
/// someone types would stall the field they are typing into. A change arriving mid-evaluation
/// supersedes it, and the previous result stays on screen until the new one lands rather than the
/// views blanking on every keystroke (Principle III).
@MainActor
@Observable
final class FilterCoordinator {
    private(set) var filter = Filter()
    /// Nil when nothing is being asked, which is different from a filter that matches nothing.
    private(set) var result: FilterResult?
    private(set) var breakdown: [CategoryTotal] = []

    let activity = ActivityIndicator()

    private var root: ScannedItem?
    private var rootPath = ""
    private var work: Task<Void, Never>?

    private let evaluator = FilterEvaluator()
    private let analyzer = CategoryAnalyzer()

    var isFiltering: Bool { !filter.isEmpty }
    var matchedNothing: Bool { result?.isEmpty ?? false }

    func present(root: ScannedItem, path: String) {
        self.root = root
        rootPath = path
        recompute()
    }

    func clearScan() {
        work?.cancel()
        work = nil
        root = nil
        rootPath = ""
        filter = Filter()
        result = nil
        breakdown = []
        activity.end()
    }

    func update(_ filter: Filter) {
        guard filter != self.filter else { return }
        self.filter = filter
        recompute()
    }

    func clearFilter() {
        update(Filter())
    }

    /// Selecting a category from the breakdown narrows to it, and selecting it again lets it go
    /// (FR-044).
    func toggleCategory(_ category: FileCategory) {
        var next = filter
        if next.categories.contains(category) {
            next.categories.remove(category)
        } else {
            next.categories.insert(category)
        }
        update(next)
    }

    private func recompute() {
        guard let root else { return }

        work?.cancel()
        activity.begin("Filtering")

        let filter = filter
        let path = rootPath
        let evaluator = evaluator
        let analyzer = analyzer

        work = Task {
            // Released on every path, including a superseded one, or the bar would report that
            // filtering is still happening long after it stopped.
            defer { self.activity.end() }

            let computed = await Task.detached(priority: .userInitiated) {
                let result = filter.isEmpty
                    ? nil
                    : evaluator.evaluate(filter, over: root, rootPath: path)
                let breakdown = analyzer.breakdown(
                    of: root, rootPath: path, matching: result?.matches
                )
                return (result, breakdown)
            }.value

            guard !Task.isCancelled else { return }
            self.result = computed.0
            self.breakdown = computed.1
        }
    }
}
