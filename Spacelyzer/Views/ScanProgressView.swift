import SwiftUI

/// Progress while a scan runs. Reports what is being measured and how much has been found, rather
/// than an indeterminate spinner, because a scan can run far longer than two seconds (FR-003).
struct ScanProgressView: View {
    let totals: ScanTotals
    let currentPath: String
    let formatter: SizeFormatter
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Measuring")
                    .font(.headline)
                Spacer()
                // Cancellation stays reachable throughout; background work must never block its
                // own cancel control (FR-071).
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            Text("\(formatter.string(from: totals.measuredBytes)) across \(totals.itemsSeen) items")
                .font(.callout)
                .monospacedDigit()

            Text(currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Everything the scan could not read, with the reason for each (FR-005).
///
/// The list is bounded and scrollable. An earlier version let it grow to the length of the
/// skipped set, which on a real scan pushed its own toggle off the bottom of the window and made
/// it impossible to close again.
struct SkippedLocationsView: View {
    let skipped: [(path: String, reason: SkipReason)]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label("\(skipped.count) locations skipped", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(skipped.count) locations skipped")
            .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(skipped.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(entry.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .font(.caption)
                                Spacer(minLength: 12)
                                Text(entry.reason.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
                // Bounded so the toggle above it always stays reachable.
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal)
    }
}
