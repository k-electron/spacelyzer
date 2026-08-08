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
struct SkippedLocationsView: View {
    let skipped: [(path: String, reason: SkipReason)]

    var body: some View {
        DisclosureGroup {
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                    Spacer()
                    Text(entry.reason.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("\(skipped.count) locations skipped", systemImage: "exclamationmark.triangle")
                .font(.callout)
        }
        .padding(.horizontal)
    }
}
