import SwiftUI

/// Asking a question of the result, with what has been asked kept visible and one way to take it
/// all back (FR-041).
struct FilterBarView: View {
    let filter: Filter
    let result: FilterResult?
    let isWorking: Bool
    let formatter: SizeFormatter
    let onChange: (Filter) -> Void

    @State private var extensionEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)

                TextField("Filter by name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                sizeMenu
                categoryMenu
                extensionField

                if isWorking {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 8)

                summary
            }

            if !filter.isEmpty {
                chips
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { filter.text },
            set: { text in
                var next = filter
                next.text = text
                onChange(next)
            }
        )
    }

    /// Thresholds rather than a free number field. Someone hunting for space thinks in "bigger
    /// than about a gigabyte", not in bytes.
    private var sizeMenu: some View {
        Menu {
            Button("Any size") { withMinimum(nil) }
            Divider()
            ForEach(Self.thresholds, id: \.bytes) { threshold in
                Button("Larger than \(threshold.label)") { withMinimum(threshold.bytes) }
            }
        } label: {
            Label(minimumLabel, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var categoryMenu: some View {
        Menu {
            Button("Any kind") {
                var next = filter
                next.categories = []
                onChange(next)
            }
            Divider()
            ForEach(FileCategory.allCases, id: \.self) { category in
                Button {
                    var next = filter
                    if next.categories.contains(category) {
                        next.categories.remove(category)
                    } else {
                        next.categories.insert(category)
                    }
                    onChange(next)
                } label: {
                    if filter.categories.contains(category) {
                        Label(category.label, systemImage: "checkmark")
                    } else {
                        Text(category.label)
                    }
                }
            }
        } label: {
            Label(categoryLabel, systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var extensionField: some View {
        TextField("Extension", text: $extensionEntry)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .onSubmit {
                guard let normalized = Filter.normalizedExtension(extensionEntry) else { return }
                var next = filter
                next.fileExtensions.insert(normalized)
                extensionEntry = ""
                onChange(next)
            }
    }

    @ViewBuilder
    private var summary: some View {
        if let result {
            Text("\(result.matchCount) matching · \(formatter.string(from: result.combinedSize))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(activeDescriptions, id: \.self) { description in
                    Text(description)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }

                // One action takes all of it back, however many conditions are in force.
                Button("Clear") { onChange(Filter()) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.link)
            }
        }
    }

    private func withMinimum(_ bytes: Int64?) {
        var next = filter
        next.minimumSize = bytes
        onChange(next)
    }

    private var minimumLabel: String {
        guard let minimum = filter.minimumSize else { return "Any size" }
        return "> \(formatter.string(from: minimum))"
    }

    private var categoryLabel: String {
        switch filter.categories.count {
        case 0: "Any kind"
        case 1: filter.categories.first?.label ?? "Any kind"
        default: "\(filter.categories.count) kinds"
        }
    }

    /// Every condition in force, spelled out. A filter the user cannot see is one they cannot
    /// undo deliberately.
    private var activeDescriptions: [String] {
        var parts: [String] = []
        let needle = filter.text.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { parts.append("name contains “\(needle)”") }
        for category in filter.categories.sorted(by: { $0.label < $1.label }) {
            parts.append(category.label.lowercased())
        }
        for suffix in filter.fileExtensions.sorted() {
            parts.append(".\(suffix)")
        }
        if let minimum = filter.minimumSize {
            parts.append("larger than \(formatter.string(from: minimum))")
        }
        if let maximum = filter.maximumSize {
            parts.append("smaller than \(formatter.string(from: maximum))")
        }
        if filter.modifiedAfter != nil || filter.modifiedBefore != nil {
            parts.append("modified in range")
        }
        return parts
    }

    private static let thresholds: [(label: String, bytes: Int64)] = [
        ("1 MB", 1_000_000),
        ("10 MB", 10_000_000),
        ("100 MB", 100_000_000),
        ("1 GB", 1_000_000_000),
        ("10 GB", 10_000_000_000),
    ]
}

/// A filter that matches nothing is a dead end unless it says so and offers the way out.
struct FilterEmptyStateView: View {
    let onClear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No item in this analysis satisfies every filter in force.")
        } actions: {
            Button("Clear Filters", action: onClear)
        }
    }
}
