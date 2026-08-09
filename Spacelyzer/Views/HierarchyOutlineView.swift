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
    let rootPath: String
    let formatter: SizeFormatter
    let sortOrder: SortOrder
    let selection: SelectionCoordinator

    /// Which folders are open, held here rather than in each row.
    ///
    /// With the flag on the row, revealing something deep took one render pass per level: a row
    /// could only react to the selection once its parent had opened and rendered it. The scroll
    /// then raced that cascade and often arrived before the destination row existed, which is
    /// what made following the treemap into the tree unreliable. Held together, every ancestor
    /// opens in a single pass and the row is there to scroll to.
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List {
                NodeRow(
                    item: root,
                    path: rootPath,
                    parentTotal: root.cumulativeSize,
                    formatter: formatter,
                    sortOrder: sortOrder,
                    selection: selection,
                    expanded: $expanded
                )
            }
            .listStyle(.inset)
            .onAppear { expanded.insert(rootPath) }
            .onChange(of: selection.revealToken) { _, _ in
                reveal(proxy: proxy)
            }
        }
    }

    private func reveal(proxy: ScrollViewProxy) {
        guard let path = selection.selectedPath else { return }
        expanded.formUnion(Self.ancestors(of: path, under: rootPath))

        Task {
            // Opening the ancestors and laying the new rows out are still two separate passes,
            // so the scroll waits a turn. Retried a few times because a very deep reveal can
            // take more than one, and scrolling to a row that does not exist yet does nothing.
            for attempt in 0..<5 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 40 : 60))
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(path, anchor: .center)
                }
            }
        }
    }

    /// Every folder between the root and this path, the root included.
    static func ancestors(of path: String, under rootPath: String) -> Set<String> {
        guard path.hasPrefix(rootPath) else { return [] }

        var result: Set<String> = [rootPath]
        var current = rootPath
        for component in path.dropFirst(rootPath.count).split(separator: "/").dropLast() {
            current += "/" + component
            result.insert(current)
        }
        return result
    }
}

private struct NodeRow: View {
    let item: ScannedItem
    let path: String
    let parentTotal: Int64
    let formatter: SizeFormatter
    let sortOrder: SortOrder
    let selection: SelectionCoordinator
    @Binding var expanded: Set<String>
    /// Sorted once per ordering rather than once per render.
    ///
    /// Every row observes the shared selection, so a single click re-renders all of them. With
    /// the sort inline, that meant re-sorting every expanded folder's children on every click —
    /// seven milliseconds apiece for a folder of fifty thousand, which is what made clicking
    /// large folders feel unreliable.
    @State private var sortedChildren: [ScannedItem] = []

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(path) },
            set: { isOpen in
                if isOpen { expanded.insert(path) } else { expanded.remove(path) }
            }
        )
    }

    var body: some View {
        if item.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                // Siblings within a directory always have distinct names, so the name is a valid
                // identity here and costs nothing to derive.
                ForEach(sortedChildren, id: \.name) { child in
                    NodeRow(
                        item: child,
                        path: path + "/" + child.name,
                        parentTotal: item.cumulativeSize,
                        formatter: formatter,
                        sortOrder: sortOrder,
                        selection: selection,
                        expanded: $expanded
                    )
                }
            } label: {
                label
            }
            .task(id: sortOrder) { sortedChildren = sortOrder.sort(item.children) }
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
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selection.isSelected(path) ? Color.accentColor.opacity(0.25) : .clear)
        )
        .contentShape(.rect)
        .onTapGesture { selection.select(path, from: .outline) }
        .id(path)
        // Ignore rather than combine. Combining lets the children's own values through, and the
        // name is drawn truncated, so a leaf row announced itself as "Apple Color Emoji...." with
        // no size at all. Ignoring them leaves only the description below, which is complete.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(selection.isSelected(path) ? [.isSelected] : [])
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
        parts.append(item.itemCount == 1 ? "1 item" : "\(item.itemCount) items")
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
        // No tooltip alongside the hover swap. It would install a second tracking mechanism on
        // every row in the tree to say what the row already says when pointed at.
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}
