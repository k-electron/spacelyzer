import CoreGraphics
import Foundation

/// Finds which rectangle is under a point, fast enough to keep up with a moving pointer.
///
/// A uniform grid over the canvas rather than a walk of the tree. SC-005 asks for a response
/// within 100 ms at a million items, and at that size even one pass over the node list per pointer
/// move is too much. Building the grid costs one pass; every lookup after that touches a handful
/// of candidates.
nonisolated struct SpatialIndex: Sendable {
    private let nodes: [TreemapNode]
    private let bounds: CGRect
    private let columns: Int
    private let rows: Int
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let cells: [[Int]]

    init(layout: TreemapLayout) {
        nodes = layout.nodes
        bounds = layout.bounds

        guard !layout.nodes.isEmpty, layout.bounds.width > 0, layout.bounds.height > 0 else {
            columns = 0
            rows = 0
            cellWidth = 0
            cellHeight = 0
            cells = []
            return
        }

        // Roughly one cell per handful of nodes, capped so the grid itself never becomes the cost.
        let target = max(1, min(64, Int(Double(layout.nodes.count).squareRoot() / 2)))
        columns = target
        rows = target
        cellWidth = layout.bounds.width / CGFloat(target)
        cellHeight = layout.bounds.height / CGFloat(target)

        var buckets = [[Int]](repeating: [], count: target * target)
        for (index, node) in layout.nodes.enumerated() {
            let minColumn = Self.clamp(
                Int((node.rect.minX - layout.bounds.minX) / max(cellWidth, .leastNonzeroMagnitude)),
                to: target
            )
            let maxColumn = Self.clamp(
                Int((node.rect.maxX - layout.bounds.minX) / max(cellWidth, .leastNonzeroMagnitude)),
                to: target
            )
            let minRow = Self.clamp(
                Int((node.rect.minY - layout.bounds.minY) / max(cellHeight, .leastNonzeroMagnitude)),
                to: target
            )
            let maxRow = Self.clamp(
                Int((node.rect.maxY - layout.bounds.minY) / max(cellHeight, .leastNonzeroMagnitude)),
                to: target
            )

            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    buckets[row * target + column].append(index)
                }
            }
        }
        cells = buckets
    }

    /// The deepest rectangle containing the point.
    ///
    /// Layout emits parents before children, so the highest index among the matches is the one
    /// drawn on top — which is the one the user believes they are pointing at.
    func node(at point: CGPoint) -> TreemapNode? {
        guard !cells.isEmpty, bounds.contains(point) else { return nil }

        let column = Self.clamp(Int((point.x - bounds.minX) / cellWidth), to: columns)
        let row = Self.clamp(Int((point.y - bounds.minY) / cellHeight), to: rows)

        var best: Int?
        for index in cells[row * columns + column] where nodes[index].rect.contains(point) {
            if best == nil || index > best! { best = index }
        }
        return best.map { nodes[$0] }
    }

    private static func clamp(_ value: Int, to count: Int) -> Int {
        min(max(value, 0), count - 1)
    }
}
