import SwiftData
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case itemCount = "Items"
    case modified = "Date Modified"

    var id: String { rawValue }

    func sort(_ nodes: [ScanNode]) -> [ScanNode] {
        switch self {
        case .size: nodes.sorted { $0.cumulativeSize > $1.cumulativeSize }
        case .name: nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .itemCount: nodes.sorted { $0.itemCount > $1.itemCount }
        case .modified: nodes.sorted { $0.modified > $1.modified }
        }
    }
}

/// The expandable hierarchy, largest first by default because the point is finding what is big
/// (FR-024). Rows are built recursively through `DisclosureGroup` rather than `OutlineGroup` so
/// the sort order can actually be applied — `OutlineGroup` takes a key path, which cannot see the
/// current selection of sort.
struct HierarchyOutlineView: View {
    let root: ScanNode
    let formatter: SizeFormatter
    @Binding var sortOrder: SortOrder

    var body: some View {
        List {
            NodeRow(
                node: root,
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
    let node: ScanNode
    let parentTotal: Int64
    let formatter: SizeFormatter
    let sortOrder: SortOrder
    var startsExpanded: Bool = false

    @State private var isExpanded = false

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(sortOrder.sort(node.children), id: \.persistentModelID) { child in
                    NodeRow(
                        node: child,
                        parentTotal: node.cumulativeSize,
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
                .foregroundStyle(node.category.color)
                .frame(width: 16)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if node.countedElsewhere {
                Text("counted elsewhere")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let share = formatter.share(of: node.cumulativeSize, in: parentTotal) {
                Text(share)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(formatter.string(from: node.cumulativeSize))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)

            Text("\(node.itemCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbol: String {
        switch node.kind {
        case .directory: "folder"
        case .package: "app.badge"
        case .symlink: "arrow.turn.up.right"
        case .remainder: "ellipsis.rectangle"
        case .file: "doc"
        }
    }

    private var accessibilityDescription: String {
        var parts = [node.name, formatter.string(from: node.cumulativeSize)]
        if let share = formatter.share(of: node.cumulativeSize, in: parentTotal) {
            parts.append("\(share) of parent")
        }
        parts.append("\(node.itemCount) items")
        if node.countedElsewhere {
            parts.append("counted elsewhere")
        }
        return parts.joined(separator: ", ")
    }
}
