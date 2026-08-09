import CoreGraphics
import SwiftUI

/// What the colours in the treemap stand for.
nonisolated enum TreemapColoring: String, CaseIterable, Identifiable, Sendable {
    /// Each immediate child of the displayed root gets its own hue. Usually the most useful of
    /// the three: it answers "which folder is taking the space" without reading anything.
    case folder = "Folder"
    case category = "Kind"
    case depth = "Depth"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .folder: "Each top-level folder has its own colour."
        case .category: "Colour by kind of file."
        case .depth: "Lighter shades sit deeper in the hierarchy."
        }
    }

    /// Hues spaced by the golden angle, which keeps neighbouring branches far apart in colour
    /// however many there are, instead of collapsing into a gradient the way evenly dividing the
    /// wheel does once the count grows.
    static func branchColor(_ branch: Int) -> Color {
        guard branch >= 0 else { return .gray }
        let hue = (Double(branch) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    /// Includes the shading for depth, because how much of the signal depth carries differs by
    /// mode: elsewhere it is a hint that keeps nesting readable, and in depth mode it is the
    /// entire point.
    func color(for node: TreemapNode) -> Color {
        if node.isRemainder { return Color(nsColor: .quaternaryLabelColor) }
        let depth = Double(min(6, max(0, node.depth)))

        switch self {
        case .folder:
            return Self.branchColor(node.branch).opacity(0.55 + depth * 0.07)
        case .category:
            return node.category.color.opacity(0.55 + depth * 0.07)
        case .depth:
            // Brightness rather than opacity. An opacity ramp over one hue is nearly invisible
            // against a dark background, which left the mode saying nothing.
            return Color(hue: 0.58, saturation: 0.55, brightness: 0.28 + depth * 0.11)
        }
    }
}

/// Draws the laid-out rectangles and turns pointer movement into hover and drilling.
///
/// One `Canvas` for the whole picture rather than a view per item: at a million items the view
/// tree alone would be the bottleneck, whereas immediate-mode drawing costs only what is on
/// screen. Nothing is laid out here — the canvas draws rectangles that already exist.
struct TreemapCanvas: View {
    let snapshot: LayoutSnapshot
    let formatter: SizeFormatter
    let coloring: TreemapColoring
    let isRecomputing: Bool
    let selection: SelectionCoordinator
    let onDrill: (TreemapNode) -> Void
    let onResize: (CGRect) -> Void

    @State private var hovered: TreemapNode?

    /// Enough to make the picture navigable without building an element per rectangle. A layout
    /// can hold tens of thousands of them, and the outline is the complete accessible equivalent
    /// (research R7), so this exposes the ones worth going to rather than all of them.
    private static let accessibleNodeLimit = 100

    var body: some View {
        ZStack {
            // Two layers on purpose. The rectangles depend only on the layout and the colouring,
            // so pointing at something redraws the thin overlay instead of all twenty thousand
            // of them. Drawing everything on every pointer move saturated the main thread on
            // large folders, and clicks arriving behind that backlog were what felt flaky.
            TreemapBaseLayer(snapshot: snapshot, coloring: coloring).equatable()

            TreemapOverlayLayer(hovered: hovered, selected: selectedNode)
                .allowsHitTesting(false)
        }
        // Not a GeometryReader reporting through onChange. That pattern misses changes when the
        // container resizes without the child's identity changing, which is exactly what dragging
        // a window edge or a split divider does, and it left the treemap drawn at its first size.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            onResize(CGRect(origin: .zero, size: size))
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point):
                // Straight to the spatial index, never a walk of the tree, so this keeps up
                // with the pointer no matter how large the scan (SC-005).
                hovered = snapshot.index.node(at: point)
            case .ended:
                hovered = nil
            }
        }
        .onTapGesture(count: 2) { location in
            if let node = snapshot.index.node(at: location) { onDrill(node) }
        }
        // Selection deliberately does not go through a second tap gesture. Two tap recognisers on
        // one view make every single click wait out the double-click interval to find out which
        // it was, which reads as the click having been missed. A zero-distance drag settles on
        // mouse-up with nothing to disambiguate, so selection is immediate and a double click
        // simply selects twice on its way to drilling.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    // A remainder carries its parent's path, so clicking one selects the folder
                    // it stands for. It also asks the outline to open that folder in full, since
                    // seeing the items it stands for is the reason to click it.
                    let node = snapshot.index.node(at: value.location)
                    selection.select(
                        node?.path,
                        from: .treemap,
                        revealingContents: node?.isRemainder ?? false
                    )
                }
        )
        // Kept interactive and visible while a new layout computes, with only a quiet hint
        // that work is happening.
        .opacity(isRecomputing ? 0.85 : 1)
        .overlay(alignment: .bottom) { readout }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
        .accessibilityChildren { accessibleRegions }
    }

    /// The largest drawn regions, exposed so the picture can be navigated rather than being one
    /// opaque element. Focusing one selects it through the same coordinator the pointer uses, so
    /// VoiceOver and the mouse cannot end up disagreeing (research R7, Principle V).
    private var accessibleRegions: some View {
        ZStack(alignment: .topLeading) {
            ForEach(largestNodes) { node in
                Color.clear
                    .frame(width: max(1, node.rect.width), height: max(1, node.rect.height))
                    .offset(x: node.rect.minX, y: node.rect.minY)
                    .accessibilityElement()
                    .accessibilityLabel(label(for: node))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { selection.select(node.path, from: .treemap) }
            }
        }
    }

    private var largestNodes: [TreemapNode] {
        snapshot.layout.nodes
            .filter { !$0.isRemainder && $0.depth > 0 }
            .sorted { $0.size > $1.size }
            .prefix(Self.accessibleNodeLimit)
            .map { $0 }
    }

    private func label(for node: TreemapNode) -> String {
        var parts = [node.name, formatter.string(from: node.size)]
        if let share = formatter.share(of: node.size, in: snapshot.layout.displayedTotal) {
            parts.append("\(share) of what is shown")
        }
        return parts.joined(separator: ", ")
    }

    /// Resolved through the layout's path index rather than by scanning the node list, because
    /// this runs on every draw.
    private var selectedNode: TreemapNode? {
        selection.selectedPath.flatMap { snapshot.node(withPath: $0) }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered {
            HStack(spacing: 8) {
                Circle()
                    .fill(hovered.isRemainder ? Color.secondary : hovered.category.color)
                    .frame(width: 8, height: 8)
                Text(hovered.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if hovered.isRemainder {
                    Text("\(hovered.collapsedCount) items")
                        .foregroundStyle(.secondary)
                }
                Text(formatter.string(from: hovered.size))
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(.rect(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    /// The outline is the accessible equivalent of this view (research R7); the canvas reports
    /// what it is showing rather than pretending area is navigable by ear.
    private var accessibilitySummary: String {
        guard !snapshot.layout.isEmpty else { return "Treemap, empty" }
        return "Treemap of \(snapshot.layout.nodes.count) regions totalling "
            + formatter.string(from: snapshot.layout.displayedTotal)
    }
}

/// Every rectangle, drawn once per layout.
///
/// Equatable on the layout's identity and the colouring, which is what lets SwiftUI skip the
/// whole thing when the only change was where the pointer is.
private struct TreemapBaseLayer: View, Equatable {
    let snapshot: LayoutSnapshot
    let coloring: TreemapColoring

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot.id == rhs.snapshot.id && lhs.coloring == rhs.coloring
    }

    var body: some View {
        Canvas(opaque: false) { context, _ in
            for node in snapshot.layout.nodes {
                let rect = node.rect
                guard rect.width >= 1, rect.height >= 1 else { continue }

                let path = Path(rect)
                context.fill(path, with: .color(coloring.color(for: node)))

                // FR-028: without a boundary a viewer cannot tell which parent a rectangle
                // belongs to.
                if rect.width > 3, rect.height > 3 {
                    context.stroke(
                        path,
                        with: .color(.black.opacity(node.depth == 0 ? 0.35 : 0.22)),
                        lineWidth: 0.5
                    )
                }

                if rect.width > 64, rect.height > 20 {
                    Self.label(node, in: rect, context: &context)
                }
            }
        }
    }

    private static func label(
        _ node: TreemapNode,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        let available = CGSize(width: rect.width - 8, height: rect.height - 6)
        guard available.width > 16, available.height > 10 else { return }
        guard let fitted = Self.fitted(node.name, within: available, context: context) else {
            return
        }

        // A dark plate under the text so a name stays readable over any category colour.
        let plate = CGRect(
            x: rect.minX + 3,
            y: rect.minY + 3,
            width: fitted.size.width + 4,
            height: fitted.size.height + 2
        )

        // Clipped as well as measured. Text metrics and glyph rasterisation disagree at the edges
        // for some fonts, and a hard boundary is the only way a label cannot escape its rectangle.
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.fill(
                Path(roundedRect: plate, cornerRadius: 2),
                with: .color(.black.opacity(0.35))
            )
            layer.draw(
                fitted.text,
                at: CGPoint(x: plate.minX + 2, y: plate.minY + 1),
                anchor: .topLeading
            )
        }
    }

    /// The longest form of a name that fits, shortened with an ellipsis when the whole of it will
    /// not.
    ///
    /// Measured unconstrained on purpose. Measuring against the available width reports the size
    /// the text would take if it were allowed to wrap, but `draw(at:anchor:)` renders it on one
    /// line at its natural width — so a constrained measure says a long name fits and the drawing
    /// then runs past the edge of its rectangle.
    private static func fitted(
        _ name: String,
        within available: CGSize,
        context: GraphicsContext
    ) -> (text: GraphicsContext.ResolvedText, size: CGSize)? {
        let unbounded = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        func resolve(_ string: String) -> (GraphicsContext.ResolvedText, CGSize) {
            var text = context.resolve(Text(string).font(.system(size: 10, weight: .medium)))
            text.shading = .color(.white)
            return (text, text.measure(in: unbounded))
        }

        var (text, size) = resolve(name)
        guard size.height <= available.height else { return nil }
        if size.width <= available.width { return (text, size) }

        // Estimate from the overshoot rather than dropping one character at a time, then correct
        // at most a couple of times. Names are laid out on every draw, so this cannot be a search.
        var characters = Array(name)
        for _ in 0..<3 {
            let ratio = available.width / size.width
            let keep = min(
                characters.count - 1,
                max(1, Int(Double(characters.count) * ratio) - 1)
            )
            guard keep >= 1 else { return nil }
            characters = Array(characters.prefix(keep))
            (text, size) = resolve(String(characters) + "…")
            if size.width <= available.width { return (text, size) }
        }
        return nil
    }
}

/// Just the hover outline and the selection. Two shapes at most, so this is the only thing that
/// has to be redrawn while the pointer moves.
private struct TreemapOverlayLayer: View {
    let hovered: TreemapNode?
    let selected: TreemapNode?

    var body: some View {
        Canvas(opaque: false) { context, _ in
            // Draw-time only. Highlighting must never trigger a relayout, or a selection could
            // not cross between the views inside SC-004's 100 ms.
            if let hovered, hovered.rect.width > 2, hovered.rect.height > 2 {
                context.stroke(
                    Path(hovered.rect), with: .color(.primary.opacity(0.6)), lineWidth: 1.5
                )
            }

            if let selected, selected.rect.width > 2, selected.rect.height > 2 {
                let path = Path(selected.rect.insetBy(dx: 1, dy: 1))
                context.fill(path, with: .color(.white.opacity(0.18)))
                context.stroke(path, with: .color(.white), lineWidth: 2.5)
                context.stroke(Path(selected.rect), with: .color(.black.opacity(0.7)), lineWidth: 1)
            }
        }
    }
}
