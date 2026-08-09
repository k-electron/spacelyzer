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
    func matches(_ item: ScannedItem) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty,
           item.name.range(of: needle, options: .caseInsensitive) == nil {
            return false
        }
        if !categories.isEmpty, !categories.contains(item.category) {
            return false
        }
        if !fileExtensions.isEmpty {
            guard let suffix = Self.fileExtension(of: item.name),
                  fileExtensions.contains(suffix)
            else { return false }
        }
        if let minimumSize, item.cumulativeSize < minimumSize { return false }
        if let maximumSize, item.cumulativeSize > maximumSize { return false }
        if let modifiedAfter, item.modified < modifiedAfter { return false }
        if let modifiedBefore, item.modified > modifiedBefore { return false }
        return true
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
