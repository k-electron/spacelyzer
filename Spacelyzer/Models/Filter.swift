import Foundation

/// The questions a user can ask of a finished scan (FR-037 through FR-040).
///
/// A value with no behaviour beyond deciding whether one item satisfies it, so the evaluator that
/// walks the tree can be tested without an interface and this can be tested without a tree.
nonisolated struct Filter: Sendable, Equatable {
    var text: String = ""
    var categories: Set<FileCategory> = []
    /// Lowercased and without the dot, however the user typed them.
    var fileExtensions: Set<String> = []
    var minimumSize: Int64?
    var maximumSize: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && categories.isEmpty
            && fileExtensions.isEmpty
            && minimumSize == nil
            && maximumSize == nil
            && modifiedAfter == nil
            && modifiedBefore == nil
    }

    /// Conditions combine conjunctively: an item has to satisfy every one that is set.
    ///
    /// Size is tested against the cumulative figure so that "bigger than a gigabyte" surfaces the
    /// folders that are, which is usually what someone hunting for space means by it.
    ///
    /// Asking one item costs preparing the filter, which is the right trade for a single question
    /// and the wrong one for a million. Anything walking a tree prepares once through
    /// ``prepared()`` and asks that.
    func matches(_ item: ScannedItem) -> Bool {
        prepared().matches(item)
    }

    func prepared() -> Prepared { Prepared(self) }

    /// The same conditions with everything that does not vary between items lifted out.
    ///
    /// Trimming the search text reads as free, and is, until it happens once per node: at a
    /// million items it was a million strings allocated to arrive at the same answer every time.
    nonisolated struct Prepared: Sendable {
        /// Nil when no name condition is set, which is cheaper to test than an empty string and
        /// says the same thing.
        let needle: String?
        let categories: Set<FileCategory>
        let fileExtensions: Set<String>
        let minimumSize: Int64?
        let maximumSize: Int64?
        let modifiedAfter: Date?
        let modifiedBefore: Date?

        init(_ filter: Filter) {
            let trimmed = filter.text.trimmingCharacters(in: .whitespaces)
            needle = trimmed.isEmpty ? nil : trimmed
            categories = filter.categories
            fileExtensions = filter.fileExtensions
            minimumSize = filter.minimumSize
            maximumSize = filter.maximumSize
            modifiedAfter = filter.modifiedAfter
            modifiedBefore = filter.modifiedBefore
        }

        func matches(_ item: ScannedItem) -> Bool {
            if needle != nil, !contains(item.name) {
                return false
            }
            if !categories.isEmpty, !categories.contains(item.category) {
                return false
            }
            if !fileExtensions.isEmpty {
                guard let suffix = Filter.fileExtension(of: item.name),
                      fileExtensions.contains(suffix)
                else { return false }
            }
            if let minimumSize, item.cumulativeSize < minimumSize { return false }
            if let maximumSize, item.cumulativeSize > maximumSize { return false }
            if let modifiedAfter, item.modified < modifiedAfter { return false }
            if let modifiedBefore, item.modified > modifiedBefore { return false }
            return true
        }

        /// Does this name contain the search text, ignoring case?
        ///
        /// Left to Foundation, which was measured against the obvious alternative and won. Both
        /// sides are usually ASCII, where folding case is subtracting 32 from a byte, so a
        /// hand-rolled search over the UTF-8 looked like an easy way past the Unicode machinery
        /// for the common case. It made filtering a million items about a quarter slower:
        /// `range(of:options:)` already has a fast path for short ASCII strings, and getting at
        /// the bytes of a name short enough to live inside its own `String` means materialising a
        /// buffer that was not there. Recorded here because it is a tempting change to make twice.
        func contains(_ name: String) -> Bool {
            guard let needle else { return true }
            return name.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// Nil for a name with no extension, and for a dotfile, whose leading dot names the file
    /// rather than its type.
    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let suffix = name[name.index(after: dot)...]
        return suffix.isEmpty ? nil : suffix.lowercased()
    }

    static func normalizedExtension(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every condition in force, spelled out one per phrase.
    ///
    /// Lives here rather than in the bar that draws them: a filter the user cannot see is one
    /// they cannot undo deliberately (FR-041), which makes this worth testing without a view.
    func descriptions(sizes: SizeFormatter) -> [String] {
        var parts: [String] = []

        let needle = text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { parts.append("name contains “\(needle)”") }

        for category in categories.sorted(by: { $0.label < $1.label }) {
            parts.append(category.label.lowercased())
        }
        for suffix in fileExtensions.sorted() {
            parts.append(".\(suffix)")
        }
        if let minimumSize { parts.append("larger than \(sizes.string(from: minimumSize))") }
        if let maximumSize { parts.append("smaller than \(sizes.string(from: maximumSize))") }

        func day(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .omitted)
        }
        switch (modifiedAfter, modifiedBefore) {
        case let (after?, before?): parts.append("modified \(day(after)) to \(day(before))")
        case let (after?, nil): parts.append("modified after \(day(after))")
        case let (nil, before?): parts.append("modified before \(day(before))")
        case (nil, nil): break
        }

        return parts
    }
}
