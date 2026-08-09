import Foundation
import SwiftData

nonisolated enum ExclusionRefusal: Error, Equatable {
    case wouldExcludeScanRoot
    case alreadyExcluded

    /// FR-012 requires a refusal to explain itself rather than simply not working.
    var explanation: String {
        switch self {
        case .wouldExcludeScanRoot:
            """
            That folder is the one being measured. Excluding it would leave nothing to scan, so \
            choose a folder inside it instead.
            """
        case .alreadyExcluded:
            "That folder is already excluded."
        }
    }
}

/// The folders the user has asked to be left out, and the rules about changing that list
/// (FR-010 through FR-013).
@MainActor
struct ExclusionRules {
    let context: ModelContext

    func all() -> [ExclusionRule] {
        let descriptor = FetchDescriptor<ExclusionRule>(
            sortBy: [SortDescriptor(\.path)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func excludedURLs() -> [URL] {
        all().map { URL(fileURLWithPath: $0.path) }
    }

    /// Refuses rather than silently declining, so the caller has something to show (FR-012).
    @discardableResult
    func add(_ url: URL, scanRoot: URL?) throws -> ExclusionRule {
        let path = url.standardizedFileURL.path

        if let scanRoot, scanRoot.standardizedFileURL.path == path {
            throw ExclusionRefusal.wouldExcludeScanRoot
        }
        if all().contains(where: { $0.path == path }) {
            throw ExclusionRefusal.alreadyExcluded
        }

        let rule = ExclusionRule(path: path)
        context.insert(rule)
        try? context.save()
        return rule
    }

    func remove(_ rule: ExclusionRule) {
        context.delete(rule)
        try? context.save()
    }

    /// Whether a displayed result predates the current list, which is what makes it stale rather
    /// than merely old (FR-013).
    func resultIsStale(scannedWith excluded: [URL]) -> Bool {
        Set(excluded.map(\.standardizedFileURL.path)) != Set(all().map(\.path))
    }
}
