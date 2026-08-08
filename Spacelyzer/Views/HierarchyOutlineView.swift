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

            if let share = formatter.share(of: item.cumulativeSize, in: parentTotal) {
                Text(share)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

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
