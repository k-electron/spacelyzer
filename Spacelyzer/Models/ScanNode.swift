import Foundation
import SwiftData

nonisolated enum NodeKind: Int, Codable, Sendable {
    case file
    case directory
    /// An application bundle. Measured whole during the scan and only enumerated if the user
    /// asks to look inside it (FR-022).
    case package
    case symlink
    /// Synthesised during layout to stand for siblings too small to draw (FR-032). Has no
    /// filesystem counterpart.
    case remainder
}

@Model
final class ScanNode {
    var name: String
    var kind: NodeKind
    var category: FileCategory

    /// Space occupied on disk by this item alone. Zero for directories.
    var ownSize: Int64
    /// `ownSize` plus every descendant. Filled in by the rollup once children are known.
    var cumulativeSize: Int64
    /// Descendants including self.
    var itemCount: Int

    var created: Date
    var modified: Date
    var accessed: Date

    /// Set when this node's bytes were already counted at another path, which is how a hard link
    /// appears everywhere it exists while contributing its size exactly once (FR-006).
    var countedElsewhere: Bool
    var unreadable: Bool
    /// True for a package whose contents have not been enumerated yet.
    var hasUnexpandedContents: Bool

    var parent: ScanNode?

    @Relationship(deleteRule: .cascade, inverse: \ScanNode.parent)
    var children: [ScanNode]

    init(
        name: String,
        kind: NodeKind,
        category: FileCategory,
        ownSize: Int64 = 0,
        cumulativeSize: Int64 = 0,
        itemCount: Int = 1,
        created: Date = .distantPast,
        modified: Date = .distantPast,
        accessed: Date = .distantPast,
        countedElsewhere: Bool = false,
        unreadable: Bool = false,
        hasUnexpandedContents: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.category = category
        self.ownSize = ownSize
        self.cumulativeSize = cumulativeSize
        self.itemCount = itemCount
        self.created = created
        self.modified = modified
        self.accessed = accessed
        self.countedElsewhere = countedElsewhere
        self.unreadable = unreadable
        self.hasUnexpandedContents = hasUnexpandedContents
        self.children = []
    }

    var isExpandable: Bool {
        !children.isEmpty || hasUnexpandedContents
    }

    /// Reconstructed by walking parents rather than stored, since a stored path per node would
    /// dwarf everything else in the store.
    var path: String {
        var components = [name]
        var current = parent
        while let node = current {
            components.append(node.name)
            current = node.parent
        }
        return components.reversed().joined(separator: "/")
    }
}
