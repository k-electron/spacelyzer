import Foundation

nonisolated struct FilterResult: Sendable, Equatable {
    /// Items that satisfy the conditions themselves.
    let matches: Set<String>
    /// Matches plus the folders on the way down to them, so the outline can show the path to a
    /// match rather than a flat list of orphans.
    let retained: Set<String>
    let matchCount: Int
    /// What the matches occupy together, counted once.
    let combinedSize: Int64

    var isEmpty: Bool { matchCount == 0 }
}

/// Answers a filter against a finished scan.
///
/// Never rescans and never touches the filesystem. Pure, but not cheap — a million nodes is a
/// million comparisons — so callers run it off the main actor rather than while the user types.
nonisolated struct FilterEvaluator: Sendable {

    func evaluate(_ filter: Filter, over root: ScannedItem, rootPath: String) -> FilterResult {
        var matches: Set<String> = []
        var retained: Set<String> = []
        var combinedSize: Int64 = 0

        @discardableResult
        func walk(_ item: ScannedItem, path: String, insideMatch: Bool) -> Bool {
            let selfMatches = filter.matches(item)
            if selfMatches {
                matches.insert(path)
                // Only when no ancestor already matched. A folder and the files inside it can
                // both satisfy the same condition, and adding both would report the same bytes
                // twice.
                if !insideMatch { combinedSize += item.cumulativeSize }
            }

            var descendantMatched = false
            for child in item.children {
                let childMatched = walk(
                    child,
                    path: path + "/" + child.name,
                    insideMatch: insideMatch || selfMatches
                )
                descendantMatched = descendantMatched || childMatched
            }

            if selfMatches || descendantMatched { retained.insert(path) }
            return selfMatches || descendantMatched
        }

        walk(root, path: rootPath, insideMatch: false)

        return FilterResult(
            matches: matches,
            retained: retained,
            matchCount: matches.count,
            combinedSize: combinedSize
        )
    }
}
