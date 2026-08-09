import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case itemCount = "Items"
    case modified = "Date Modified"

    var id: String { rawValue }

    func sort(_ items: [ScannedItem]) -> [ScannedItem] {
        switch self {
        case .size: items.sorted { $0.cumulativeSize > $1.cumulativeSize }
        case .name: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .itemCount: items.sorted { $0.itemCount > $1.itemCount }
        case .modified: items.sorted { $0.modified > $1.modified }
        }
    }
}

/// The expandable hierarchy, largest first by default because the point is finding what is big
/// (FR-024).
///
/// Rows use a recursive `DisclosureGroup` rather than `OutlineGroup`, which takes a key path and
/// therefore cannot see the selected sort order — with it, the sort control would silently do
/// nothing.
struct HierarchyOutlineView: View {
    let root: ScannedItem
    let formatter: SizeFormatter
    let sortOrder: SortOrder

    var body: some View {
        List {
            NodeRow(
                item: root,
                parentTotal: root.cumulativeSize,
                formatter: formatter,
                sortOrder: sortOrder,
                startsExpanded: true
            )
        }
        .listStyle(.inset)
    }
}

private struct NodeRow: View {
    let item: ScannedItem
    let parentTotal: Int64
    let formatter: SizeFormatter
    let sortOrder: SortOrder
    var startsExpanded: Bool = false

    @State private var isExpanded = false

    var body: some View {
        if item.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                // Siblings within a directory always have distinct names, so the name is a valid
                // identity here and costs nothing to derive.
                ForEach(sortOrder.sort(item.children), id: \.name) { child in
                    NodeRow(
                        item: child,
                        parentTotal: item.cumulativeSize,
                        formatter: formatter,
                        sortOrder: sortOrder
                    )
                }
            } label: {
                label
            }
            .onAppear { if startsExpanded { isExpanded = true } }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(item.category.color)
                .frame(width: 16)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if item.countedElsewhere {
                Text("counted elsewhere")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ShareBar(
                fraction: parentTotal > 0 ? Double(item.cumulativeSize) / Double(parentTotal) : 0,
                text: formatter.share(of: item.cumulativeSize, in: parentTotal)
            )

            Text(formatter.string(from: item.cumulativeSize))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)

            Text("\(item.itemCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbol: String {
        switch item.kind {
        case .directory: "folder"
        case .package: "app.badge"
        case .symlink: "arrow.turn.up.right"
        case .remainder: "ellipsis.rectangle"
        case .file: "doc"
        }
    }

    private var accessibilityDescription: String {
        var parts = [item.name, formatter.string(from: item.cumulativeSize)]
        if let share = formatter.share(of: item.cumulativeSize, in: parentTotal) {
            parts.append("\(share) of parent")
        }
        parts.append("\(item.itemCount) items")
        if item.countedElsewhere {
            parts.append("counted elsewhere")
        }
        return parts.joined(separator: ", ")
    }
}

/// A row's share of its parent, drawn rather than spelled out.
///
/// A column of percentages is a column of numbers to read one at a time; a column of bars can be
/// scanned in one pass. The number is still there for anyone who wants it — pointing at the bar
/// swaps it in, and the slot keeps a fixed width so nothing shifts when it does.
private struct ShareBar: View {
    let fraction: Double
    let text: String?

    @State private var isHovering = false

    private static let width: CGFloat = 54

    var body: some View {
        ZStack(alignment: .leading) {
            if isHovering, let text {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Self.width, alignment: .trailing)
            } else {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: Self.width, height: 5)
                // The accent rather than the row's category colour: the icon already carries the
                // category, and a column of bars is only scannable if the bars share one colour.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(1, Self.width * clamped), height: 5)
            }
        }
        .frame(width: Self.width, height: 14)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .help(text ?? "")
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}
