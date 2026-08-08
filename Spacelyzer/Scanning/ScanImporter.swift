import Foundation
import SwiftData

/// Turns a scanned value tree into `ScanNode` models on a background context.
///
/// This is the expensive half of a scan — measured at roughly two and a half times the traversal
/// itself — so it must not run on the main actor. Doing it there is what made a large scan feel
/// like a freeze rather than a wait.
@ModelActor
actor ScanImporter {
    func importTree(_ item: ScannedItem) throws -> PersistentIdentifier {
        let root = insert(item, parent: nil)
        try modelContext.save()
        return root.persistentModelID
    }

    @discardableResult
    private func insert(_ item: ScannedItem, parent: ScanNode?) -> ScanNode {
        let node = ScanNode(
            name: item.name,
            kind: item.kind,
            category: item.category,
            ownSize: item.ownSize,
            cumulativeSize: item.cumulativeSize,
            itemCount: item.itemCount,
            created: item.created,
            modified: item.modified,
            accessed: item.accessed,
            countedElsewhere: item.countedElsewhere,
            unreadable: item.unreadable,
            hasUnexpandedContents: item.hasUnexpandedContents
        )
        // Setting the parent is enough. `children` is the inverse of this relationship, so
        // appending to it as well made every node pay for the same link twice.
        node.parent = parent
        modelContext.insert(node)

        for child in item.children {
            insert(child, parent: node)
        }
        return node
    }
}
