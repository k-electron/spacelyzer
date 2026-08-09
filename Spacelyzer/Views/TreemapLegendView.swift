import SwiftUI

/// Explains what the colours mean (FR-029). Colour without a key is decoration.
struct TreemapLegendView: View {
    struct Entry: Identifiable {
        let id: String
        let label: String
        let color: Color
    }

    /// Only what is actually on screen. A legend listing colours the user cannot see sends them
    /// hunting for something that is not there.
    let entries: [Entry]
    /// Shown when the colouring has no discrete keys to list, as depth shading does not.
    let caption: String?

    var body: some View {
        if entries.isEmpty {
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ForEach(entries) { entry in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.color.opacity(0.8))
                        .frame(width: 10, height: 10)
                    Text(entry.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The path from the scanned root down to whatever the treemap is currently showing, with every
/// step in it clickable so the way back out is never more than one click (FR-031).
struct TreemapTrailView: View {
    let trail: [String]
    let onNavigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    onNavigate(index)
                } label: {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(index == trail.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(index == trail.count - 1)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
