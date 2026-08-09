import CoreGraphics
import Foundation
import SwiftUI

/// A layout and the index built from it, produced together so the view never holds one without
/// the other.
nonisolated struct LayoutSnapshot: Sendable {
    let layout: TreemapLayout
    let index: SpatialIndex
    /// Identity for the rectangles as a whole. Comparing it is how the drawing of twenty thousand
    /// rectangles is skipped when only the pointer moved.
    let id: UUID
    /// Path to position in `layout.nodes`, so highlighting the selection is a lookup rather than
    /// a scan of every rectangle on every draw.
    private let positionsByPath: [String: Int]

    /// The largest drawn regions, ranked here rather than in the view.
    ///
    /// These are what the canvas exposes as accessibility elements. Deriving them meant sorting
    /// every rectangle in the layout, and the view re-derived them whenever the selection moved —
    /// twenty thousand comparisons on the click path, for an answer that only changes when the
    /// layout does.
    let largestNodes: [TreemapNode]

    /// Enough to make the picture navigable without building an element per rectangle. The
    /// outline is the complete accessible equivalent (research R7), so this exposes the ones
    /// worth going to rather than all of them.
    static let accessibleNodeLimit = 100

    init(layout: TreemapLayout, index: SpatialIndex) {
        self.layout = layout
        self.index = index
        id = UUID()

        largestNodes = layout.nodes
            .filter { !$0.isRemainder && $0.depth > 0 }
            .sorted { $0.size > $1.size }
            .prefix(Self.accessibleNodeLimit)
            .map { $0 }

        // Remainders are skipped deliberately: one carries the path of the parent it stands for,
        // so indexing it would shadow the real rectangle of that folder.
        var positions: [String: Int] = [:]
        for (position, node) in layout.nodes.enumerated() where !node.isRemainder {
            positions[node.path] = position
        }
        positionsByPath = positions
    }

    static let empty = LayoutSnapshot(layout: .empty, index: SpatialIndex(layout: .empty))

    func node(withPath path: String) -> TreemapNode? {
        positionsByPath[path].map { layout.nodes[$0] }
    }
}

/// Owns which subtree the treemap is showing and keeps its layout current.
///
/// Layout runs off the main actor and arrives as an immutable snapshot. A resize or a drill that
/// lands while one is in flight supersedes it, and the previous picture stays on screen and stays
/// interactive until the replacement is ready — blanking the view during relayout would destroy
/// the user's context to show them nothing (Principle III, research R6).
@MainActor
@Observable
final class LayoutCoordinator {
    private(set) var snapshot: LayoutSnapshot = .empty
    let activity = ActivityIndicator()

    /// Displayed root last. Everything before it is the way back out (FR-031).
    private var stack: [(item: ScannedItem, path: String)] = []
    private var bounds: CGRect = .zero
    private var layoutTask: Task<Void, Never>?
    private let engine = SquarifiedLayout()
    /// The filtered subset both views are showing, or nil when nothing is being filtered.
    private var retained: Set<String>?

    var layout: TreemapLayout { snapshot.layout }
    var hasContent: Bool { !stack.isEmpty }
    var canNavigateOut: Bool { stack.count > 1 }
    var trail: [String] { stack.map(\.item.name) }
    var displayedRootPath: String? { stack.last?.path }

    func present(root: ScannedItem, path: String) {
        stack = [(root, path)]
        recompute()
    }

    func clear() {
        layoutTask?.cancel()
        layoutTask = nil
        stack = []
        snapshot = .empty
        activity.end()
    }

    /// Narrows the picture to the filtered subset. The same set the outline is showing, so the
    /// two cannot describe different things (FR-042).
    func apply(retained: Set<String>?) {
        guard retained != self.retained else { return }
        self.retained = retained
        recompute()
    }

    /// How long a size has to hold still before it is worth laying out for.
    ///
    /// A resize arrives once a frame while a window edge, the split divider, or the details panel
    /// is moving. Squarifying has no cancellation point, so a superseded layout runs to completion
    /// anyway, and starting one per frame puts a dozen full layouts of the same tree on the
    /// processor at once — which stutters the very movement being watched.
    private static let resizeSettleTime = Duration.milliseconds(90)

    func resize(to newBounds: CGRect) {
        guard newBounds.size != bounds.size, newBounds.width > 0, newBounds.height > 0 else {
            return
        }
        bounds = newBounds
        recompute(afterSettling: true)
    }

    /// A remainder stands for many items and has no subtree of its own, so it is not a place to
    /// go. Neither is a file.
    func canDrill(into node: TreemapNode) -> Bool {
        guard !node.isRemainder, let current = stack.last else { return false }
        return Self.resolve(path: node.path, from: current.item, at: current.path)
            .map { !$0.children.isEmpty } ?? false
    }

    func drill(into node: TreemapNode) {
        guard canDrill(into: node), let current = stack.last,
              let target = Self.resolve(path: node.path, from: current.item, at: current.path)
        else { return }
        stack.append((target, node.path))
        recompute()
    }

    func navigateOut() {
        guard canNavigateOut else { return }
        stack.removeLast()
        recompute()
    }

    func navigate(toDepth depth: Int) {
        guard depth >= 0, depth < stack.count - 1 else { return }
        stack.removeSubrange((depth + 1)...)
        recompute()
    }

    private func recompute(afterSettling: Bool = false) {
        guard let current = stack.last, bounds.width > 0, bounds.height > 0 else { return }

        layoutTask?.cancel()
        activity.begin("Drawing")

        let engine = engine
        let bounds = bounds
        let item = current.item
        let path = current.path
        let retained = retained

        layoutTask = Task {
            // Released on every path, including a superseded one. Returning early without it
            // leaves the indicator claimed forever, so the canvas stays dimmed and the app says
            // it is working while sitting idle.
            defer { self.activity.end() }

            if afterSettling {
                // Cancelled by the next resize, so a burst of them costs one layout rather than
                // one each. The canvas stretches the picture it already has in the meantime.
                try? await Task.sleep(for: Self.resizeSettleTime)
                guard !Task.isCancelled else { return }
            }

            let computed = await Task.detached(priority: .userInitiated) {
                let layout = engine.layout(
                    root: item, rootPath: path, in: bounds, retained: retained
                )
                // Built alongside the layout rather than on arrival, because indexing a large
                // layout on the main actor would undo the point of computing it off one.
                return LayoutSnapshot(layout: layout, index: SpatialIndex(layout: layout))
            }.value

            guard !Task.isCancelled else { return }
            self.snapshot = computed
        }
    }

    /// Walks from the displayed root down the path the node recorded during layout.
    nonisolated static func resolve(
        path: String,
        from root: ScannedItem,
        at rootPath: String
    ) -> ScannedItem? {
        if path == rootPath { return root }
        guard path.hasPrefix(rootPath + "/") else { return nil }

        var current = root
        for component in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
