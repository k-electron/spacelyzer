import Foundation

nonisolated struct CategoryTotal: Sendable, Identifiable, Equatable {
    var id: FileCategory { category }
    let category: FileCategory
    let bytes: Int64
    let itemCount: Int
    /// Of the nodes considered, so a breakdown of a filtered subset sums to all of that subset
    /// rather than to a fraction of the whole scan.
    let share: Double
}

/// What kind of thing is filling the disk (FR-044).
///
/// Totals come from each item's own size rather than its cumulative one. A folder's cumulative
/// figure already contains its children, so adding both would count the same bytes twice; own
/// sizes add up to exactly what the scan measured.
nonisolated struct CategoryAnalyzer: Sendable {

    /// `matching` narrows the breakdown to a filter's results. A node counts when it matched or
    /// when it sits inside something that did — matching a folder means asking what is in it, and
    /// counting only the folder itself would report nothing, since a folder holds no bytes of its
    /// own. Totalled this way the breakdown agrees with the combined size the filter reports.
    func breakdown(
        of root: ScannedItem,
        rootPath: String,
        matching: Set<String>? = nil
    ) -> [CategoryTotal] {
        var bytes: [FileCategory: Int64] = [:]
        var counts: [FileCategory: Int] = [:]
        var total: Int64 = 0

        func walk(_ item: ScannedItem, path: String, insideMatch: Bool) {
            let isMatch = insideMatch || (matching?.contains(path) ?? true)

            // Hard-linked data reachable by several paths contributes where it was first counted,
            // preserving the count-once invariant.
            if isMatch, !item.countedElsewhere, item.ownSize > 0 || item.kind != .directory {
                bytes[item.category, default: 0] += item.ownSize
                counts[item.category, default: 0] += 1
                total += item.ownSize
            }

            for child in item.children {
                walk(child, path: path + "/" + child.name, insideMatch: isMatch)
            }
        }

        walk(root, path: rootPath, insideMatch: false)

        return bytes.keys
            .map { category in
                CategoryTotal(
                    category: category,
                    bytes: bytes[category] ?? 0,
                    itemCount: counts[category] ?? 0,
                    share: total > 0 ? Double(bytes[category] ?? 0) / Double(total) : 0
                )
            }
            // Biggest first, with a stable tie-break so equal categories do not swap places
            // between one breakdown and the next.
            .sorted {
                $0.bytes != $1.bytes
                    ? $0.bytes > $1.bytes
                    : $0.category.label < $1.category.label
            }
    }
}
