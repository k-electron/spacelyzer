import SwiftUI

/// What kind of thing is filling the disk, biggest first, and a way to narrow to one (FR-044).
struct CategoryBreakdownView: View {
    let totals: [CategoryTotal]
    let selected: Set<FileCategory>
    let formatter: SizeFormatter
    let onSelect: (FileCategory) -> Void

    var body: some View {
        if totals.isEmpty {
            ContentUnavailableView(
                "No breakdown yet",
                systemImage: "chart.bar",
                description: Text("Analyze a folder or a volume to see what kinds of file fill it.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(totals) { total in
                        row(total)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(_ total: CategoryTotal) -> some View {
        let isSelected = selected.contains(total.category)

        return Button {
            onSelect(total.category)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(total.category.color.opacity(0.85))
                        .frame(width: 10, height: 10)

                    Text(total.category.label)
                        .fontWeight(isSelected ? .semibold : .regular)

                    Spacer(minLength: 12)

                    Text(total.itemCount == 1 ? "1 item" : "\(total.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Text(formatter.string(from: total.bytes))
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)

                    Text(total.share.formatted(.percent.precision(.fractionLength(1))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }

                // The bar carries the comparison; the numbers are for confirming it.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(total.category.color.opacity(0.85))
                            .frame(width: max(2, geometry.size.width * total.share))
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(total.category.label), \(formatter.string(from: total.bytes)), "
                + total.share.formatted(.percent.precision(.fractionLength(1)))
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
