import CoreGraphics
import SwiftUI

/// Draws the laid-out rectangles and turns pointer movement into hover and drilling.
///
/// One `Canvas` for the whole picture rather than a view per item: at a million items the view
/// tree alone would be the bottleneck, whereas immediate-mode drawing costs only what is on
/// screen. Nothing is laid out here — the canvas draws rectangles that already exist.
struct TreemapCanvas: View {
    let snapshot: LayoutSnapshot
    let formatter: SizeFormatter
    let isRecomputing: Bool
    let onDrill: (TreemapNode) -> Void
    let onResize: (CGRect) -> Void

    @State private var hovered: TreemapNode?

    var body: some View {
        Canvas(opaque: false) { context, size in
            draw(&context, size: size)
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
        .onTapGesture { location in
            if let node = snapshot.index.node(at: location) { onDrill(node) }
        }
        // Kept interactive and visible while a new layout computes, with only a quiet hint
        // that work is happening.
        .opacity(isRecomputing ? 0.85 : 1)
        .overlay(alignment: .bottom) { readout }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        for node in snapshot.layout.nodes {
            let rect = node.rect
            guard rect.width >= 1, rect.height >= 1 else { continue }

            let path = Path(rect)
            context.fill(path, with: .color(fill(for: node)))

            // FR-028: without a boundary a viewer cannot tell which parent a rectangle belongs to.
            if rect.width > 3, rect.height > 3 {
                context.stroke(
                    path,
                    with: .color(.black.opacity(node.depth == 0 ? 0.35 : 0.22)),
                    lineWidth: 0.5
                )
            }

            if rect.width > 64, rect.height > 20 {
                label(node, in: rect, context: &context)
            }
        }

        if let hovered, hovered.rect.width > 2, hovered.rect.height > 2 {
            context.stroke(Path(hovered.rect), with: .color(.primary), lineWidth: 2)
        }
    }

    private func label(_ node: TreemapNode, in rect: CGRect, context: inout GraphicsContext) {
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

    /// Deeper rectangles sit lighter than their parents, so nesting reads even where two siblings
    /// share a category colour.
    private func fill(for node: TreemapNode) -> Color {
        if node.isRemainder {
            return Color(nsColor: .quaternaryLabelColor)
        }
        let lift = min(0.35, Double(node.depth) * 0.07)
        return node.category.color.opacity(0.55 + lift)
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
