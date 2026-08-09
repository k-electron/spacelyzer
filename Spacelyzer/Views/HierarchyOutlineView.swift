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

/// One line of the outline, already positioned in the list.
nonisolated struct OutlineRow: Identifiable, Sendable {
    enum Content: Sendable {
        case item(ScannedItem)
        /// The children a folder is not showing, offered rather than hidden.
        case more(count: Int, bytes: Int64)
    }

    let id: String
    let depth: Int
    let parentTotal: Int64
    let content: Content
    let isExpandable: Bool
    let isExpanded: Bool
}

/// The expandable hierarchy, largest first by default because the point is finding what is big
/// (FR-024).
///
/// The visible tree is flattened into one array of rows rather than built from nested disclosure
/// groups. Nesting gave the list no linear order, so it could neither scroll to a row it had not
/// already built nor tell how many rows it had — which is why revealing something the user had
/// scrolled away from silently did nothing. Flat, every row has a position.
struct HierarchyOutlineView: View {
    let root: ScannedItem
    let rootPath: String
    let formatter: SizeFormatter
    let sortOrder: SortOrder
    let selection: SelectionCoordinator

    /// Which folders are open. Held here rather than per row, so revealing something deep opens
    /// every ancestor in one pass instead of one level per render.
    @State private var expanded: Set<String> = []
    /// Folders the user has asked to see past the cap on how many children a folder shows.
    @State private var fullyShown: Set<String> = []
    @State private var cache = RowCache()

    /// How many children a folder shows before offering the rest.
    ///
    /// Flattening still costs a row per visible child, so an open folder of fifty thousand would
    /// make the list heavy for as long as it stayed open. Two hundred is far more than fits on
    /// screen, and with the biggest first, nothing below it is what anyone is hunting for.
    static let childLimit = 200

    private var rows: [OutlineRow] {
        cache.rows(
            for: RowKey(
                rootPath: rootPath,
                total: root.cumulativeSize,
                order: sortOrder,
                expanded: expanded,
                fullyShown: fullyShown
            )
        ) {
            Self.flatten(
                root,
                path: rootPath,
                order: sortOrder,
                expanded: expanded,
                fullyShown: fullyShown
            )
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.id)
                        .id(row.id)
                }
            }
            .listStyle(.inset)
            .onAppear { expanded.insert(rootPath) }
            .onChange(of: selection.revealToken) { _, _ in
                reveal(proxy: proxy)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selection.selectedPath },
            set: { chosen in selection.select(chosen, from: .outline) }
        )
    }

    private func reveal(proxy: ScrollViewProxy) {
        guard let path = selection.selectedPath else { return }

        expanded.formUnion(Self.ancestors(of: path, under: rootPath))

        // The target may sit past its folder's cap, and a row that is not in the list cannot be
        // scrolled to. Only its own folder opens in full; the rest of the way down stays capped.
        if let parent = Self.parent(of: path, under: rootPath) {
            fullyShown.insert(parent)
        }

        // A click on a tile standing for the items too small to draw asks to see them.
        if selection.revealContentsOfSelection {
            expanded.insert(path)
            fullyShown.insert(path)
        }

        Task {
            // Opening folders and laying the new rows out are separate passes, so the scroll
            // waits a turn. Once the rows exist the list knows where the target sits, whether or
            // not it has been drawn yet.
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(path, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: OutlineRow) -> some View {
        switch row.content {
        case let .item(item):
            ItemRow(
                item: item,
                row: row,
                formatter: formatter,
                onToggle: { toggle(row.id) }
            )
        case let .more(count, bytes):
            MoreRow(
                count: count,
                bytes: bytes,
                depth: row.depth,
                formatter: formatter,
                onShow: { fullyShown.insert(parentOfMoreRow(row.id)) }
            )
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// A more-row's id is its folder's path with a marker, so it cannot collide with a real file.
    private func parentOfMoreRow(_ id: String) -> String {
        String(id.dropLast(Self.moreRowSuffix.count))
    }

    static let moreRowSuffix = "\u{0000}more"

    /// Walks the open parts of the tree in display order.
    ///
    /// Only open folders are ordered, so a collapsed one costs nothing however large it is.
    static func flatten(
        _ item: ScannedItem,
        path: String,
        order: SortOrder,
        expanded: Set<String>,
        fullyShown: Set<String>,
        depth: Int = 0,
        parentTotal: Int64? = nil,
        into rows: inout [OutlineRow]
    ) {
        let isOpen = expanded.contains(path)
        rows.append(
            OutlineRow(
                id: path,
                depth: depth,
                parentTotal: parentTotal ?? item.cumulativeSize,
                content: .item(item),
                isExpandable: !item.children.isEmpty,
                isExpanded: isOpen
            )
        )
        guard isOpen, !item.children.isEmpty else { return }

        let ordered = order.sort(item.children)
        let shown = fullyShown.contains(path) ? ordered.count : min(childLimit, ordered.count)

        for child in ordered.prefix(shown) {
            flatten(
                child,
                path: path + "/" + child.name,
                order: order,
                expanded: expanded,
                fullyShown: fullyShown,
                depth: depth + 1,
                parentTotal: item.cumulativeSize,
                into: &rows
            )
        }

        let hidden = ordered.dropFirst(shown)
        if !hidden.isEmpty {
            rows.append(
                OutlineRow(
                    id: path + moreRowSuffix,
                    depth: depth + 1,
                    parentTotal: item.cumulativeSize,
                    content: .more(
                        count: hidden.count,
                        bytes: hidden.reduce(0) { $0 + $1.cumulativeSize }
                    ),
                    isExpandable: false,
                    isExpanded: false
                )
            )
        }
    }

    static func flatten(
        _ item: ScannedItem,
        path: String,
        order: SortOrder,
        expanded: Set<String>,
        fullyShown: Set<String>
    ) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        rows.reserveCapacity(256)
        flatten(
            item,
            path: path,
            order: order,
            expanded: expanded,
            fullyShown: fullyShown,
            into: &rows
        )
        return rows
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

    /// The folder this path sits in, or nil when it is the root.
    static func parent(of path: String, under rootPath: String) -> String? {
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let components = path.dropFirst(rootPath.count).split(separator: "/").dropLast()
        return components.reduce(rootPath) { $0 + "/" + $1 }
    }
}

/// What the flattened rows depend on. Anything else changing — the selection, most of all — must
/// not cost a walk of the tree.
private struct RowKey: Equatable {
    let rootPath: String
    let total: Int64
    let order: SortOrder
    let expanded: Set<String>
    let fullyShown: Set<String>
}

/// Memoises the flattened rows.
///
/// Selecting something re-renders the list, and rebuilding every row for a click that changed no
/// structure would put the walk back on the hot path it was moved off.
@MainActor
private final class RowCache {
    private var key: RowKey?
    private var rows: [OutlineRow] = []

    func rows(for key: RowKey, build: () -> [OutlineRow]) -> [OutlineRow] {
        if self.key == key { return rows }
        self.key = key
        rows = build()
        return rows
    }
}

private struct ItemRow: View {
    let item: ScannedItem
    let row: OutlineRow
    let formatter: SizeFormatter
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Indentation and the triangle are drawn rather than inherited from a disclosure
            // group, which is the price of a flat list and a small one.
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)

            Group {
                if row.isExpandable {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 12)

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
                fraction: row.parentTotal > 0
                    ? Double(item.cumulativeSize) / Double(row.parentTotal)
                    : 0,
                text: formatter.share(of: item.cumulativeSize, in: row.parentTotal)
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
        .contentShape(.rect)
        // Ignore rather than combine. Combining lets the children's own values through, and the
        // name is drawn truncated, so a leaf row announced itself as "Apple Color Emoji...." with
        // no size at all.
        .accessibilityElement(children: .ignore)
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
        if let share = formatter.share(of: item.cumulativeSize, in: row.parentTotal) {
            parts.append("\(share) of parent")
        }
        parts.append(item.itemCount == 1 ? "1 item" : "\(item.itemCount) items")
        if item.countedElsewhere {
            parts.append("counted elsewhere")
        }
        return parts.joined(separator: ", ")
    }
}

/// Says how much is behind it rather than hiding it. The same promise the treemap's remainder
/// makes: nothing disappears from the totals without being named.
private struct MoreRow: View {
    let count: Int
    let bytes: Int64
    let depth: Int
    let formatter: SizeFormatter
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Show \(count) smaller items")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(formatter.string(from: bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
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
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}
