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
                dateMenu
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
    /// than about a gigabyte", not in bytes. Both bounds can be set at once, which is what makes
    /// "between 100 MB and 1 GB" reachable (FR-039).
    private var sizeMenu: some View {
        Menu {
            Button("Any size") {
                var next = filter
                next.minimumSize = nil
                next.maximumSize = nil
                onChange(next)
            }
            Section("Larger than") {
                ForEach(Self.thresholds, id: \.bytes) { threshold in
                    Button(threshold.label) { withMinimum(threshold.bytes) }
                }
            }
            Section("Smaller than") {
                ForEach(Self.thresholds, id: \.bytes) { threshold in
                    Button(threshold.label) { withMaximum(threshold.bytes) }
                }
            }
        } label: {
            Label(sizeLabel, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Relative spans rather than a calendar. The question people actually have is "what have I
    /// not touched in a year", not "what changed on the fourteenth" (FR-040).
    private var dateMenu: some View {
        Menu {
            Button("Any time") { withDates(after: nil, before: nil) }
            Section("Modified within") {
                ForEach(Self.spans, id: \.days) { span in
                    Button(span.label) {
                        withDates(after: Self.daysAgo(span.days), before: nil)
                    }
                }
            }
            Section("Untouched for over") {
                ForEach(Self.spans, id: \.days) { span in
                    Button(span.label) {
                        withDates(after: nil, before: Self.daysAgo(span.days))
                    }
                }
            }
        } label: {
            Label(dateLabel, systemImage: "calendar")
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

    private func withMaximum(_ bytes: Int64?) {
        var next = filter
        next.maximumSize = bytes
        onChange(next)
    }

    private func withDates(after: Date?, before: Date?) {
        var next = filter
        next.modifiedAfter = after
        next.modifiedBefore = before
        onChange(next)
    }

    private var sizeLabel: String {
        switch (filter.minimumSize, filter.maximumSize) {
        case let (minimum?, maximum?):
            "\(formatter.string(from: minimum))–\(formatter.string(from: maximum))"
        case let (minimum?, nil): "> \(formatter.string(from: minimum))"
        case let (nil, maximum?): "< \(formatter.string(from: maximum))"
        case (nil, nil): "Any size"
        }
    }

    private var dateLabel: String {
        switch (filter.modifiedAfter, filter.modifiedBefore) {
        case (nil, nil): "Any time"
        case (_?, nil): "Recent"
        case (nil, _?): "Older"
        case (_?, _?): "Date range"
        }
    }

    private static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
    }

    private var categoryLabel: String {
        switch filter.categories.count {
        case 0: "Any kind"
        case 1: filter.categories.first?.label ?? "Any kind"
        default: "\(filter.categories.count) kinds"
        }
    }

    private var activeDescriptions: [String] {
        filter.descriptions(sizes: formatter)
    }

    private static let thresholds: [(label: String, bytes: Int64)] = [
        ("1 MB", 1_000_000),
        ("10 MB", 10_000_000),
        ("100 MB", 100_000_000),
        ("1 GB", 1_000_000_000),
        ("10 GB", 10_000_000_000),
    ]

    private static let spans: [(label: String, days: Int)] = [
        ("7 days", 7),
        ("30 days", 30),
        ("6 months", 182),
        ("1 year", 365),
        ("2 years", 730),
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
