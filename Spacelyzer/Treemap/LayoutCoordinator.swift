import CoreGraphics
import Foundation
import SwiftUI

/// A layout and the index built from it, produced together so the view never holds one without
/// the other.
nonisolated struct LayoutSnapshot: Sendable {
    let layout: TreemapLayout
    let index: SpatialIndex

    static let empty = LayoutSnapshot(layout: .empty, index: SpatialIndex(layout: .empty))
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

    var layout: TreemapLayout { snapshot.layout }
    var hasContent: Bool { !stack.isEmpty }
    var canNavigateOut: Bool { stack.count > 1 }
    var trail: [String] { stack.map(\.item.name) }

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

    func resize(to newBounds: CGRect) {
        // Resizing is continuous, so recomputing on every pixel would queue work faster than it
        // completes. Only a real change in size earns a relayout.
        guard newBounds.size != bounds.size, newBounds.width > 0, newBounds.height > 0 else {
            return
        }
        bounds = newBounds
        recompute()
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

    private func recompute() {
        guard let current = stack.last, bounds.width > 0, bounds.height > 0 else { return }

        layoutTask?.cancel()
        activity.begin("Drawing")

        let engine = engine
        let bounds = bounds
        let item = current.item
        let path = current.path

        layoutTask = Task {
            let computed = await Task.detached(priority: .userInitiated) {
                let layout = engine.layout(root: item, rootPath: path, in: bounds)
                // Built alongside the layout rather than on arrival, because indexing a large
                // layout on the main actor would undo the point of computing it off one.
                return LayoutSnapshot(layout: layout, index: SpatialIndex(layout: layout))
            }.value

            guard !Task.isCancelled else { return }
            self.snapshot = computed
            self.activity.end()
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
