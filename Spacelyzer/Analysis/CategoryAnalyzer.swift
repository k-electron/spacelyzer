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

/// Running totals per category, kept in a fixed array rather than a dictionary because there are
/// eleven categories and a million chances to look one up.
///
/// Exists so that the filtered breakdown can be accumulated inside the walk that decides what
/// matched, instead of by a second walk of the same tree afterwards.
nonisolated struct CategoryTally: Sendable {
    private var bytes = [Int64](repeating: 0, count: FileCategory.allCases.count)
    private var counts = [Int](repeating: 0, count: FileCategory.allCases.count)
    private var total: Int64 = 0

    /// Own size rather than cumulative. A folder's cumulative figure already contains its
    /// children, so adding both would count the same bytes twice.
    mutating func add(_ item: ScannedItem) {
        // Hard-linked data reachable by several paths contributes where it was first counted,
        // preserving the count-once invariant.
        guard !item.countedElsewhere, item.ownSize > 0 || item.kind != .directory else { return }
        bytes[item.category.rawValue] += item.ownSize
        counts[item.category.rawValue] += 1
        total += item.ownSize
    }

    func totals() -> [CategoryTotal] {
        FileCategory.allCases
            .filter { counts[$0.rawValue] > 0 }
            .map { category in
                CategoryTotal(
                    category: category,
                    bytes: bytes[category.rawValue],
                    itemCount: counts[category.rawValue],
                    share: total > 0 ? Double(bytes[category.rawValue]) / Double(total) : 0
                )
            }
            // Biggest first, with a stable tie-break so equal categories do not swap places
            // between one breakdown and the next.
            .sorted {
                $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.label < $1.category.label
            }
    }
}

/// What kind of thing is filling the disk (FR-044), across a whole scan.
///
/// The breakdown of a *filtered* subset is not here. It comes out of `FilterEvaluator`, which has
/// already had to decide what matched and can total it on the way past — a second walk to answer
/// a question the first one knew the answer to cost as much again as the filter itself.
nonisolated struct CategoryAnalyzer: Sendable {

    func breakdown(of root: ScannedItem) -> [CategoryTotal] {
        var tally = CategoryTally()

        func walk(_ item: ScannedItem) {
            tally.add(item)
            for child in item.children { walk(child) }
        }

        walk(root)
        return tally.totals()
    }
}
