import CoreGraphics
import Foundation

/// One laid-out rectangle. Carries everything drawing and hit testing need, so neither has to walk
/// the scan tree while the user is moving the pointer.
nonisolated struct TreemapNode: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    /// Full path, because FR-030 requires revealing it on hover and the scan tree stores only names.
    let path: String
    let kind: NodeKind
    let category: FileCategory
    let size: Int64
    let itemCount: Int
    let rect: CGRect
    let depth: Int
    /// How many items this rectangle stands for: one for a real item, more for a remainder.
    let collapsedCount: Int
    /// Which immediate child of the displayed root this descends from, or -1 for the root itself.
    /// Colouring by folder needs it, and it is far cheaper to carry down during layout than to
    /// recover afterwards by matching path prefixes.
    let branch: Int

    var isRemainder: Bool { kind == .remainder }
}

/// An immutable result handed to the view. The canvas draws these and never lays out during a
/// draw pass (research R6).
nonisolated struct TreemapLayout: Sendable, Equatable {
    /// Parents before children, so drawing in order paints nesting correctly.
    let nodes: [TreemapNode]
    let bounds: CGRect
    let displayedTotal: Int64

    static let empty = TreemapLayout(nodes: [], bounds: .zero, displayedTotal: 0)

    var isEmpty: Bool { nodes.isEmpty }
}

/// The squarified treemap algorithm, as a pure function over a scan subtree.
///
/// Imports no view framework and performs no drawing, so its geometry can be asserted on directly.
/// Given the same subtree, rectangle, and threshold it always produces the same result, which is
/// what stops rectangles from reshuffling between rescans of unchanged data.
nonisolated struct SquarifiedLayout: Sendable {
    /// Below this many square points an item is not worth a rectangle of its own and joins the
    /// remainder instead. Roughly a five-point square: small enough to still be a visible mark.
    var minimumDrawableArea: CGFloat = 25

    /// `retained` narrows the picture to a filtered subset. Siblings left out are dropped rather
    /// than dimmed, so the rectangles that remain are proportional to each other — which is what
    /// makes the treemap describe the same subset the outline is showing (FR-042).
    func layout(
        root: ScannedItem,
        rootPath: String,
        in bounds: CGRect,
        retained: Set<String>? = nil
    ) -> TreemapLayout {
        guard bounds.width > 0, bounds.height > 0 else { return .empty }
        if let retained, !retained.contains(rootPath) { return .empty }

        var nodes: [TreemapNode] = []
        var nextID = 0

        func append(
            _ item: ScannedItem,
            path: String,
            rect: CGRect,
            depth: Int,
            collapsedCount: Int,
            branch: Int
        ) {
            nodes.append(
                TreemapNode(
                    id: nextID,
                    name: item.name,
                    path: path,
                    kind: item.kind,
                    category: item.category,
                    size: item.cumulativeSize,
                    itemCount: item.itemCount,
                    rect: rect,
                    depth: depth,
                    collapsedCount: collapsedCount,
                    branch: branch
                )
            )
            nextID += 1
        }

        func place(_ item: ScannedItem, path: String, rect: CGRect, depth: Int, branch: Int) {
            append(item, path: path, rect: rect, depth: depth, collapsedCount: 1, branch: branch)
            descend(into: item, path: path, rect: rect, depth: depth, branch: branch)
        }

        func descend(into item: ScannedItem, path: String, rect: CGRect, depth: Int, branch: Int) {
            // Nothing below a rectangle this small can be told apart, so the parent stands for its
            // own contents and the recursion stops. This is also what bounds the work: a million
            // nodes cannot all be drawn into a pane a few hundred points wide.
            let area = rect.width * rect.height
            guard area >= minimumDrawableArea * 2, !item.children.isEmpty else { return }

            let inset = rect.insetBy(dx: 1, dy: 1)
            guard inset.width > 0, inset.height > 0 else { return }

            let candidates = retained.map { kept in
                item.children.filter { kept.contains(path + "/" + $0.name) }
            } ?? item.children
            guard !candidates.isEmpty else { return }

            let (drawable, remainder) = Self.partition(
                children: candidates,
                parentArea: inset.width * inset.height,
                minimumDrawableArea: minimumDrawableArea
            )
            guard !drawable.isEmpty || remainder != nil else { return }

            let areas = drawable.map { Double($0.cumulativeSize) }
                + (remainder.map { [Double($0.cumulativeSize)] } ?? [])
            let rects = Self.rectangles(forWeights: areas, in: inset)

            for (index, child) in drawable.enumerated() {
                let childRect = rects[index]
                guard childRect.width > 0, childRect.height > 0 else { continue }
                place(
                    child,
                    path: path + "/" + child.name,
                    rect: childRect,
                    depth: depth + 1,
                    // Immediate children of the displayed root start a branch; everything below
                    // inherits the one it belongs to.
                    branch: depth == 0 ? index : branch
                )
            }

            // Combined rather than dropped, so the picture never quietly loses bytes (FR-032).
            if let remainder, let remainderRect = rects.last,
               remainderRect.width > 0, remainderRect.height > 0 {
                append(
                    remainder,
                    path: path,
                    rect: remainderRect,
                    depth: depth + 1,
                    collapsedCount: remainder.itemCount,
                    branch: depth == 0 ? drawable.count : branch
                )
            }
        }

        place(root, path: rootPath, rect: bounds, depth: 0, branch: -1)

        return TreemapLayout(
            nodes: nodes,
            bounds: bounds,
            displayedTotal: root.cumulativeSize
        )
    }

    /// Splits siblings into those big enough to draw and one stand-in for the rest.
    ///
    /// Ordering is by descending size with a name tie-break, so it never depends on the order the
    /// filesystem happened to enumerate in — which is what makes the layout reproducible.
    static func partition(
        children: [ScannedItem],
        parentArea: CGFloat,
        minimumDrawableArea: CGFloat
    ) -> (drawable: [ScannedItem], remainder: ScannedItem?) {
        let total = children.reduce(Int64(0)) { $0 + $1.cumulativeSize }
        guard total > 0 else { return ([], nil) }

        let sorted = children.sorted {
            $0.cumulativeSize != $1.cumulativeSize
                ? $0.cumulativeSize > $1.cumulativeSize
                : $0.name < $1.name
        }

        var drawable: [ScannedItem] = []
        var collapsed: [ScannedItem] = []
        for child in sorted {
            let share = Double(child.cumulativeSize) / Double(total)
            if CGFloat(share) * parentArea >= minimumDrawableArea {
                drawable.append(child)
            } else {
                collapsed.append(child)
            }
        }

        guard !collapsed.isEmpty else { return (drawable, nil) }

        let collapsedBytes = collapsed.reduce(Int64(0)) { $0 + $1.cumulativeSize }
        let collapsedItems = collapsed.reduce(0) { $0 + max(1, $1.itemCount) }
        let remainder = ScannedItem(
            name: collapsed.count == 1
                ? collapsed[0].name
                : "\(collapsed.count) smaller items",
            kind: .remainder,
            category: .other,
            ownSize: 0,
            cumulativeSize: collapsedBytes,
            itemCount: collapsedItems,
            created: .distantPast,
            modified: .distantPast,
            accessed: .distantPast,
            countedElsewhere: false,
            unreadable: false,
            hasUnexpandedContents: true,
            children: []
        )
        return (drawable, remainder)
    }

    /// The squarified subdivision itself (Bruls, Huizing, and van Wijk).
    ///
    /// Rows are built greedily along the shorter side for as long as adding one more rectangle
    /// improves the worst aspect ratio in the row. Keeping rectangles near square is the whole
    /// point: slivers make areas impossible to compare by eye, which is what the picture is for.
    static func rectangles(forWeights weights: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }

        let scale = Double(bounds.width * bounds.height) / total
        let areas = weights.map { $0 * scale }

        var remaining = bounds
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }

            var count = 1
            var bestWorst = worstRatio(of: areas[index..<(index + 1)], side: side)
            while index + count < areas.count {
                let candidate = worstRatio(of: areas[index..<(index + count + 1)], side: side)
                guard candidate <= bestWorst else { break }
                bestWorst = candidate
                count += 1
            }

            let row = areas[index..<(index + count)]
            let rowSum = row.reduce(0, +)
            guard rowSum > 0 else { break }

            if remaining.width >= remaining.height {
                let stripWidth = CGFloat(rowSum) / remaining.height
                var y = remaining.minY
                for (offset, area) in row.enumerated() {
                    let height = remaining.height * CGFloat(area / rowSum)
                    result[index + offset] = CGRect(
                        x: remaining.minX, y: y, width: stripWidth, height: height
                    )
                    y += height
                }
                remaining = CGRect(
                    x: remaining.minX + stripWidth,
                    y: remaining.minY,
                    width: max(0, remaining.width - stripWidth),
                    height: remaining.height
                )
            } else {
                let stripHeight = CGFloat(rowSum) / remaining.width
                var x = remaining.minX
                for (offset, area) in row.enumerated() {
                    let width = remaining.width * CGFloat(area / rowSum)
                    result[index + offset] = CGRect(
                        x: x, y: remaining.minY, width: width, height: stripHeight
                    )
                    x += width
                }
                remaining = CGRect(
                    x: remaining.minX,
                    y: remaining.minY + stripHeight,
                    width: remaining.width,
                    height: max(0, remaining.height - stripHeight)
                )
            }

            index += count
        }

        return result
    }

    /// The worst aspect ratio a row would have if laid along `side`. Lower is squarer.
    private static func worstRatio(of areas: ArraySlice<Double>, side: Double) -> Double {
        guard let largest = areas.max(), let smallest = areas.min(),
              largest > 0, smallest > 0, side > 0
        else { return .infinity }

        let sum = areas.reduce(0, +)
        guard sum > 0 else { return .infinity }

        let sumSquared = sum * sum
        let sideSquared = side * side
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
