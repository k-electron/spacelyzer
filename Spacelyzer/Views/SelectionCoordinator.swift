import Foundation
import Observation

nonisolated enum SelectionOrigin: Sendable {
    case outline
    case treemap
}

/// The one selection both views read (FR-035).
///
/// Identified by path rather than by the scanned item itself. `ScannedItem` is a value with no
/// identity, so two files that happen to match in name and size would be indistinguishable, and
/// comparing whole subtrees on every draw would cost more than the selection is worth. A path is
/// unique, cheap to compare, and something both views already hold.
///
/// Neither view keeps its own copy. The origin is recorded so each can respond to a selection
/// without echoing it back: the outline reveals what the treemap selected, the treemap highlights
/// what the outline selected, and neither re-emits on receipt.
@MainActor
@Observable
final class SelectionCoordinator {
    private(set) var selectedPath: String?
    private(set) var origin: SelectionOrigin?

    /// Incremented on each selection that the outline should reveal. The outline expands and
    /// scrolls when this changes rather than whenever the selection is merely still set, so it
    /// reveals once instead of dragging the list back every time the view redraws.
    private(set) var revealToken = 0

    /// Set when the click was on a tile standing for items too small to draw. Selecting the
    /// folder it belongs to is only half an answer; the point of clicking it is to see what is
    /// inside, so the outline opens it in full.
    private(set) var revealContentsOfSelection = false

    func select(
        _ path: String?,
        from origin: SelectionOrigin,
        revealingContents: Bool = false
    ) {
        selectedPath = path
        self.origin = origin
        revealContentsOfSelection = revealingContents

        // Bumped on every click from the treemap, including one that lands on what is already
        // selected. Only a gesture calls this, never a redraw, so a repeat means the user asked
        // again — after scrolling the outline away, or on one of the many remainder tiles in a
        // dense folder, all of which carry the same parent path. Skipping those left most clicks
        // in a busy treemap doing nothing at all.
        if origin == .treemap, path != nil {
            revealToken += 1
        }
    }

    func clear() {
        selectedPath = nil
        origin = nil
    }

    func isSelected(_ path: String) -> Bool {
        path == selectedPath
    }

    /// Whether this path is on the way down to the selection, which is what the outline expands.
    func isOnPathToSelection(_ path: String) -> Bool {
        guard let selectedPath, selectedPath != path else { return false }
        return selectedPath.hasPrefix(path + "/")
    }

    /// Keeps the two views from disagreeing after the treemap drills somewhere the selection is
    /// not (FR-036).
    ///
    /// A selection inside the new root survives. A selection that *contains* the new root cannot
    /// be drawn as a region within it, so the root itself takes the selection — the nearest thing
    /// to it that is representable. Anything unrelated clears. What never happens is a selection
    /// that persists while being invisible.
    func resolve(withinRoot rootPath: String) {
        guard let selectedPath else { return }

        if selectedPath == rootPath || selectedPath.hasPrefix(rootPath + "/") {
            return
        }
        if rootPath.hasPrefix(selectedPath + "/") {
            self.selectedPath = rootPath
            return
        }
        clear()
    }
}
