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
}
