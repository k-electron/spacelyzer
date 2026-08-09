import Foundation
import Testing
@testable import Spacelyzer

@MainActor
@Suite("Shared selection")
struct SelectionCoordinatorTests {

    @Test("Selecting in the outline is visible to the treemap")
    func outlineSelectionReachesTheTreemap() {
        let selection = SelectionCoordinator()

        selection.select("/scan/folder/file.bin", from: .outline)

        // FR-033: the treemap highlights by asking the shared selection, not by being told
        // separately, which is what keeps the two from drifting apart.
        #expect(selection.isSelected("/scan/folder/file.bin"))
        #expect(selection.isSelected("/scan/folder") == false)
        #expect(selection.origin == .outline)
    }

    @Test("Selecting in the treemap marks the outline's ancestors for expansion")
    func treemapSelectionRevealsInTheOutline() {
        let selection = SelectionCoordinator()

        selection.select("/scan/a/b/c.bin", from: .treemap)

        // FR-034: every folder on the way down has to open for the row to be reachable.
        #expect(selection.isOnPathToSelection("/scan"))
        #expect(selection.isOnPathToSelection("/scan/a"))
        #expect(selection.isOnPathToSelection("/scan/a/b"))
        // The selection itself is not on the path to itself; it is the destination.
        #expect(selection.isOnPathToSelection("/scan/a/b/c.bin") == false)
        // Nor is a sibling that merely shares a prefix of its name.
        #expect(selection.isOnPathToSelection("/scan/ab") == false)
    }

    @Test("Only a treemap selection asks the outline to scroll")
    func revealIsRaisedOnlyByTheTreemap() {
        let selection = SelectionCoordinator()

        selection.select("/scan/a.bin", from: .outline)
        #expect(selection.revealToken == 0)

        selection.select("/scan/b.bin", from: .treemap)
        #expect(selection.revealToken == 1)

        // Dragging the list back to a row the user just clicked in the outline would fight them.
        selection.select("/scan/c.bin", from: .outline)
        #expect(selection.revealToken == 1)
    }

    @Test("Re-selecting the same thing from the same place changes nothing")
    func repeatedSelectionIsIdempotent() {
        let selection = SelectionCoordinator()

        selection.select("/scan/a.bin", from: .treemap)
        let token = selection.revealToken
        selection.select("/scan/a.bin", from: .treemap)

        // Otherwise every redraw that re-reported the same selection would scroll the list again.
        #expect(selection.revealToken == token)
    }

    @Test("A selection inside the new root survives drilling")
    func selectionInsideTheRootIsKept() {
        let selection = SelectionCoordinator()
        selection.select("/scan/a/b.bin", from: .outline)

        selection.resolve(withinRoot: "/scan/a")

        #expect(selection.selectedPath == "/scan/a/b.bin")
    }

    @Test("Drilling into the selection moves it to the new root")
    func selectionContainingTheRootBecomesTheRoot() {
        let selection = SelectionCoordinator()
        selection.select("/scan/a", from: .outline)

        // The selected folder is now the thing being displayed, so it has no region of its own
        // inside itself. The root is the nearest representable stand-in (FR-036).
        selection.resolve(withinRoot: "/scan/a/b")

        #expect(selection.selectedPath == "/scan/a/b")
    }

    @Test("A selection with nothing to do with the new root clears")
    func unrelatedSelectionClears() {
        let selection = SelectionCoordinator()
        selection.select("/scan/elsewhere/file.bin", from: .outline)

        selection.resolve(withinRoot: "/scan/a")

        // Never left set but invisible, which is the disagreement FR-036 exists to prevent.
        #expect(selection.selectedPath == nil)
    }

    @Test("A prefix that is not a path boundary is not inside the root")
    func prefixesAreNotMistakenForContainment() {
        let selection = SelectionCoordinator()
        selection.select("/scan/abc/file.bin", from: .outline)

        selection.resolve(withinRoot: "/scan/ab")

        #expect(selection.selectedPath == nil)
    }

    @Test("Resolving with nothing selected stays nothing")
    func resolvingAnEmptySelectionIsSafe() {
        let selection = SelectionCoordinator()

        selection.resolve(withinRoot: "/scan/a")

        #expect(selection.selectedPath == nil)
    }
}

@MainActor
@Suite("Revealing a selection in the outline")
struct OutlineRevealTests {

    @Test("Every folder between the root and the selection is opened at once")
    func ancestorsAreCollectedInOnePass() {
        let opened = HierarchyOutlineView.ancestors(
            of: "/scan/a/b/c/file.bin", under: "/scan"
        )

        // All of them together, because opening them one level per render pass is what left the
        // scroll arriving before its destination row existed.
        #expect(opened == ["/scan", "/scan/a", "/scan/a/b", "/scan/a/b/c"])
    }

    @Test("A selection directly in the root opens only the root")
    func shallowSelectionOpensRootOnly() {
        #expect(
            HierarchyOutlineView.ancestors(of: "/scan/file.bin", under: "/scan") == ["/scan"]
        )
    }

    @Test("A path outside the root opens nothing")
    func foreignPathOpensNothing() {
        #expect(HierarchyOutlineView.ancestors(of: "/elsewhere/x", under: "/scan").isEmpty)
    }

    @Test("Selecting the root itself opens the root")
    func rootSelectsItself() {
        #expect(HierarchyOutlineView.ancestors(of: "/scan", under: "/scan") == ["/scan"])
    }

    @Test("The folder holding the selection is identified so it can be shown in full")
    func parentIsIdentified() {
        // A folder shows only its largest few hundred children, so revealing something further
        // down the order means opening that one folder completely. Getting this wrong leaves the
        // scroll with no row to find.
        #expect(
            HierarchyOutlineView.parent(of: "/scan/a/b/file.bin", under: "/scan") == "/scan/a/b"
        )
        #expect(HierarchyOutlineView.parent(of: "/scan/file.bin", under: "/scan") == "/scan")
        #expect(HierarchyOutlineView.parent(of: "/scan", under: "/scan") == nil)
        #expect(HierarchyOutlineView.parent(of: "/elsewhere/x", under: "/scan") == nil)
    }
}
