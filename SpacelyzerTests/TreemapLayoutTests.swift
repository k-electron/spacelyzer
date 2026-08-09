import CoreGraphics
import Foundation
import Testing
@testable import Spacelyzer

/// Builds scan items directly. The layout engine is a pure function over a tree, so exercising it
/// through a real scan would only add slowness and a filesystem dependency.
private func item(
    _ name: String,
    _ size: Int64,
    kind: NodeKind = .file,
    category: FileCategory = .other,
    children: [ScannedItem] = []
) -> ScannedItem {
    ScannedItem(
        name: name,
        kind: children.isEmpty ? kind : .directory,
        category: category,
        ownSize: children.isEmpty ? size : 0,
        cumulativeSize: size,
        itemCount: max(1, children.count),
        created: .distantPast,
        modified: .distantPast,
        accessed: .distantPast,
        countedElsewhere: false,
        unreadable: false,
        hasUnexpandedContents: false,
        children: children
    )
}

private let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)

@Suite("Treemap layout")
struct TreemapLayoutTests {

    @Test("Rectangle areas are proportional to each item's share of the total")
    func areasAreProportional() throws {
        // The dominant file is half the total, so it should occupy about half the canvas (FR-027).
        let root = item("root", 1_000, children: [
            item("half.bin", 500),
            item("quarter.bin", 250),
            item("eighth.bin", 125),
            item("rest.bin", 125),
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)

        let half = try #require(layout.nodes.first { $0.name == "half.bin" })
        let quarter = try #require(layout.nodes.first { $0.name == "quarter.bin" })
        let canvasArea = Double(canvas.width * canvas.height)

        let halfShare = Double(half.rect.width * half.rect.height) / canvasArea
        let quarterShare = Double(quarter.rect.width * quarter.rect.height) / canvasArea

        // Loose tolerance: the root insets by a point on each side before subdividing.
        #expect(abs(halfShare - 0.5) < 0.02)
        #expect(abs(quarterShare - 0.25) < 0.02)
    }

    @Test("Every child rectangle lies entirely within its parent")
    func childrenStayInsideParents() {
        let root = item("root", 1_000, children: [
            item("folder", 700, children: [
                item("a.bin", 400),
                item("b.bin", 200),
                item("c.bin", 100),
            ]),
            item("loose.bin", 300),
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let folder = layout.nodes.first { $0.name == "folder" }!

        // FR-028: nesting has to be readable, which it is not if a child spills over its parent.
        let descendants = layout.nodes.filter { ["a.bin", "b.bin", "c.bin"].contains($0.name) }
        #expect(descendants.count == 3)
        for child in descendants {
            #expect(folder.rect.insetBy(dx: -0.5, dy: -0.5).contains(child.rect))
        }

        for node in layout.nodes {
            #expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(node.rect))
        }
    }

    @Test("Identical input produces an identical layout so rectangles never reshuffle")
    func layoutIsDeterministic() {
        let root = item("root", 900, children: [
            item("c.bin", 300),
            item("a.bin", 300),
            item("b.bin", 300),
        ])

        let first = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let second = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)

        #expect(first == second)

        // Equal sizes are broken by name, so enumeration order cannot leak into the picture
        // (research R6).
        let shuffled = item("root", 900, children: [
            item("b.bin", 300),
            item("c.bin", 300),
            item("a.bin", 300),
        ])
        let third = SquarifiedLayout().layout(root: shuffled, rootPath: "/root", in: canvas)

        #expect(first.nodes.map(\.name) == third.nodes.map(\.name))
        #expect(first.nodes.map(\.rect) == third.nodes.map(\.rect))
    }

    @Test("Siblings too small to draw are combined rather than dropped")
    func undrawableSiblingsBecomeARemainder() throws {
        // One dominant file and a long tail of specks, each far below a drawable area.
        var children = [item("dominant.bin", 10_000_000)]
        for index in 0..<400 {
            children.append(item("speck\(index).bin", 10))
        }
        let root = item("root", 10_004_000, children: children)

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)

        let remainder = try #require(layout.nodes.first { $0.isRemainder })
        #expect(remainder.collapsedCount >= 400)
        #expect(remainder.name.contains("smaller items"))

        // FR-032: nothing is silently omitted. Every speck is inside the remainder's total.
        #expect(remainder.size == 4_000)
        #expect(layout.nodes.filter { $0.name.hasPrefix("speck") }.isEmpty)
    }

    @Test("A single undrawable sibling keeps its own name")
    func loneRemainderIsNamed() throws {
        let root = item("root", 1_000_000, children: [
            item("dominant.bin", 999_999),
            item("speck.bin", 1),
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let remainder = try #require(layout.nodes.first { $0.isRemainder })

        // Calling one file "1 smaller items" would be worse than useless.
        #expect(remainder.name == "speck.bin")
    }

    @Test("Nodes carry the full path the hover readout needs")
    func nodesCarryPaths() throws {
        let root = item("root", 500, children: [
            item("folder", 500, children: [item("deep.bin", 500)])
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/scan/root", in: canvas)
        let deep = try #require(layout.nodes.first { $0.name == "deep.bin" })

        // The scan tree stores names only, so layout accumulates paths on the way down (FR-030).
        #expect(deep.path == "/scan/root/folder/deep.bin")
    }

    @Test("Parents are laid out before their children so nesting paints correctly")
    func parentsComeFirst() throws {
        let root = item("root", 1_000, children: [
            item("folder", 1_000, children: [item("inner.bin", 1_000)])
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let names = layout.nodes.map(\.name)

        #expect(names == ["root", "folder", "inner.bin"])
    }

    @Test("Degenerate inputs produce nothing rather than crashing")
    func degenerateInputsAreSafe() {
        let engine = SquarifiedLayout()
        let root = item("root", 0, children: [])

        #expect(engine.layout(root: root, rootPath: "/", in: .zero).isEmpty)
        #expect(engine.layout(root: root, rootPath: "/", in: canvas).nodes.count == 1)

        let empty = engine.layout(
            root: item("root", 100, children: [item("zero.bin", 0)]),
            rootPath: "/",
            in: canvas
        )
        #expect(empty.nodes.contains { $0.name == "root" })
    }

    @Test("Hit testing finds the deepest rectangle under a point")
    func hitTestingPrefersTheDeepestNode() throws {
        let root = item("root", 1_000, children: [
            item("folder", 1_000, children: [item("inner.bin", 1_000)])
        ])

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let index = SpatialIndex(layout: layout)

        // All three cover the centre. The one drawn last is the one the user is pointing at.
        let hit = try #require(index.node(at: CGPoint(x: 400, y: 300)))
        #expect(hit.name == "inner.bin")

        #expect(index.node(at: CGPoint(x: -10, y: 300)) == nil)
        #expect(index.node(at: CGPoint(x: 400, y: 9_000)) == nil)
    }

    @Test("Hit testing agrees with the rectangles the layout produced")
    func hitTestingAgreesWithGeometry() throws {
        let children = (0..<40).map { item("f\($0).bin", Int64(1_000 - $0 * 10)) }
        let root = item("root", children.reduce(Int64(0)) { $0 + $1.cumulativeSize }, children: children)

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let index = SpatialIndex(layout: layout)

        // Sampling the centre of each rectangle should find that rectangle, or something drawn
        // on top of it — never something elsewhere on the canvas.
        for node in layout.nodes where node.rect.width > 4 && node.rect.height > 4 {
            let centre = CGPoint(x: node.rect.midX, y: node.rect.midY)
            let hit = try #require(index.node(at: centre))
            #expect(hit.rect.contains(centre))
        }
    }

    @Test("Drilling resolves a rectangle back to the subtree it came from")
    func pathsResolveBackToItems() throws {
        let root = item("root", 500, children: [
            item("folder", 500, children: [item("deep.bin", 500)])
        ])

        let resolved = try #require(
            LayoutCoordinator.resolve(path: "/scan/folder", from: root, at: "/scan")
        )
        #expect(resolved.name == "folder")

        #expect(LayoutCoordinator.resolve(path: "/scan", from: root, at: "/scan")?.name == "root")
        #expect(LayoutCoordinator.resolve(path: "/elsewhere", from: root, at: "/scan") == nil)
        #expect(LayoutCoordinator.resolve(path: "/scan/missing", from: root, at: "/scan") == nil)
    }

    @Test("Rectangles stay closer to square than a naive strip layout would manage")
    func aspectRatiosStayReasonable() {
        // Squarified layout earns its complexity here. Slivers make areas impossible to compare,
        // which is the entire purpose of drawing the picture.
        let children = (0..<20).map { item("f\($0).bin", Int64(100 - $0 * 3)) }
        let root = item("root", children.reduce(Int64(0)) { $0 + $1.cumulativeSize }, children: children)

        let layout = SquarifiedLayout().layout(root: root, rootPath: "/root", in: canvas)
        let drawn = layout.nodes.filter { $0.depth == 1 && $0.rect.height > 0 }

        #expect(!drawn.isEmpty)
        for node in drawn {
            let ratio = max(node.rect.width / node.rect.height, node.rect.height / node.rect.width)
            #expect(ratio < 8)
        }
    }
}
