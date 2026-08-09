import SwiftUI

/// The measured total set against what the volume reports, with every reason they differ named
/// and explained (FR-014 through FR-017).
struct VolumeAccountingView: View {
    let accounting: VolumeAccounting
    let formatter: SizeFormatter

    @State private var explaining: UnaccountedCause?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                proportionBar
                breakdown
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(accounting.volumeName)
                .font(.title2.weight(.semibold))

            Text("\(formatter.string(from: accounting.usedBytes)) used of \(formatter.string(from: accounting.totalCapacity))")
                .foregroundStyle(.secondary)

            // Purgeable space annotates the used figure rather than joining the causes below. It
            // is already inside that figure, and mostly consists of caches the scan counted as
            // ordinary files, so adding it as a cause would claim the same bytes twice.
            if accounting.purgeableBytes > 0 {
                Text("\(formatter.string(from: accounting.purgeableBytes)) of that can be reclaimed automatically when the disk fills up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var proportionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.label) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, geometry.size.width * segment.fraction))
                    }
                }
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 18)
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary)

            HStack(spacing: 14) {
                ForEach(segments, id: \.label) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.label).font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(
                title: "Analyzed by this scan",
                bytes: accounting.measuredBytes,
                emphasis: true
            )
            Divider().padding(.vertical, 8)

            Text("Not analyzed")
                .font(.headline)
                .padding(.bottom, 6)

            ForEach(accounting.itemization) { entry in
                causeRow(entry)
            }
        }
    }

    @ViewBuilder
    private func causeRow(_ entry: UnaccountedEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                explaining = explaining == entry.cause ? nil : entry.cause
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: explaining == entry.cause ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(entry.cause.label)
                    Spacer(minLength: 12)
                    Text(sizeText(for: entry))
                        .foregroundStyle(hasSize(entry) ? .primary : .secondary)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // The closest thing to a snapshot size that exists. Shown against the remainder
            // because that is where unsizable snapshots end up.
            if entry.cause == .unattributed,
               let bound = accounting.reclaimableBoundOnRemainder,
               accounting.hasUnsizableSnapshots {
                Label(
                    "Up to \(formatter.string(from: bound)) of this could be the snapshots above — macOS reports how much space it can reclaim, but not how that splits between snapshots and cached files.",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .fixedSize(horizontal: false, vertical: true)
            }

            if explaining == entry.cause {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.cause.explanation)
                    if let reason = entry.sizeUnknownReason {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    if !entry.locations.isEmpty {
                        ForEach(entry.locations.prefix(12), id: \.self) { location in
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if entry.locations.count > 12 {
                            Text("and \(entry.locations.count - 12) more")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.callout)
                .padding(.leading, 22)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func hasSize(_ entry: UnaccountedEntry) -> Bool {
        entry.bytes != nil && !(entry.cause == .unattributed && accounting.causesOverlap)
    }

    /// An undeterminable size says so, because a zero reads as "nothing here" rather than "not
    /// known" (FR-017). An overlapping remainder says that too: the negative number underneath it
    /// is real and worth keeping in the model, but printing it reads as a bug rather than as the
    /// double count it actually reports.
    private func sizeText(for entry: UnaccountedEntry) -> String {
        if entry.cause == .unattributed, accounting.causesOverlap {
            return "Causes overlap"
        }
        guard let bytes = entry.bytes else { return "Size not known" }
        return formatter.string(from: bytes)
    }

    private func line(title: String, bytes: Int64, emphasis: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(formatter.string(from: bytes)).monospacedDigit()
        }
        .font(emphasis ? .body.weight(.medium) : .body)
    }

    private struct Segment {
        let label: String
        let fraction: Double
        let color: Color
    }

    /// Sized against capacity rather than used space, so the free portion stays visible and the
    /// measured total is never mistaken for the whole volume (FR-015).
    private var segments: [Segment] {
        let capacity = Double(max(accounting.totalCapacity, 1))
        var result: [Segment] = [
            Segment(
                label: "Analyzed",
                fraction: Double(accounting.measuredBytes) / capacity,
                color: .accentColor
            )
        ]

        let unexplained = max(0, accounting.unattributedBytes)
        let named = max(0, accounting.unaccountedBytes - unexplained)
        if named > 0 {
            result.append(
                Segment(label: "Named causes", fraction: Double(named) / capacity, color: .orange)
            )
        }
        if unexplained > 0 {
            result.append(
                Segment(label: "Unaccounted", fraction: Double(unexplained) / capacity, color: .red.opacity(0.7))
            )
        }
        result.append(
            Segment(
                label: "Free",
                fraction: Double(accounting.availableBytes) / capacity,
                color: Color(nsColor: .quaternaryLabelColor)
            )
        )
        return result
    }

    private var accessibilitySummary: String {
        let analyzed = formatter.string(from: accounting.measuredBytes)
        let used = formatter.string(from: accounting.usedBytes)
        let capacity = formatter.string(from: accounting.totalCapacity)
        return "\(analyzed) analyzed, \(used) used, of \(capacity) capacity"
    }
}
