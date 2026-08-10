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
    /// The categories the matched subset falls into, totalled during the same walk that found it.
    let breakdown: [CategoryTotal]

    var isEmpty: Bool { matchCount == 0 }
}

/// Answers a filter against a finished scan.
///
/// Never rescans and never touches the filesystem. Pure, but not cheap — a million nodes is a
/// million comparisons — so callers run it off the main actor rather than while the user types.
nonisolated struct FilterEvaluator: Sendable {

    func evaluate(_ filter: Filter, over root: ScannedItem, rootPath: String) -> FilterResult {
        let prepared = filter.prepared()
        var matches: Set<String> = []
        var retained: Set<String> = []
        var combinedSize: Int64 = 0
        var tally = CategoryTally()

        // The names on the way down to the node being visited. Identity here is the full path, and
        // building one at every node to arrive at a set holding a fiftieth of them was the whole
        // cost of applying a filter: a million strings allocated and hashed to keep twenty
        // thousand. Held as a trail, a path costs nothing until something needs to remember it.
        var trail: [String] = []

        func path() -> String {
            var result = rootPath
            for name in trail { result += "/" + name }
            return result
        }

        @discardableResult
        func walk(_ item: ScannedItem, insideMatch: Bool) -> Bool {
            let selfMatches = prepared.matches(item)
            let here = selfMatches ? path() : nil

            if let here {
                matches.insert(here)
                // Only when no ancestor already matched. A folder and the files inside it can
                // both satisfy the same condition, and adding both would report the same bytes
                // twice.
                if !insideMatch { combinedSize += item.cumulativeSize }
            }

            // A node counts towards the breakdown when it matched or when it sits inside something
            // that did — matching a folder means asking what is in it, and counting only the
            // folder itself would report nothing, since a folder holds no bytes of its own.
            let inside = insideMatch || selfMatches
            if inside { tally.add(item) }

            var descendantMatched = false
            for child in item.children {
                trail.append(child.name)
                let childMatched = walk(child, insideMatch: inside)
                trail.removeLast()
                descendantMatched = descendantMatched || childMatched
            }

            guard selfMatches || descendantMatched else { return false }
            retained.insert(here ?? path())
            return true
        }

        walk(root, insideMatch: false)

        return FilterResult(
            matches: matches,
            retained: retained,
            matchCount: matches.count,
            combinedSize: combinedSize,
            breakdown: tally.totals()
        )
    }
}
