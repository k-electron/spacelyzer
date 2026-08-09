import SwiftUI

/// What the selected item is, above what is known about it (FR-045 through FR-050).
///
/// The preview sits at the top because it answers the question fastest. A name like
/// `archive_final_v2` tells nobody anything; a thumbnail of it usually settles the matter before
/// the dates below have been read.
struct ItemDetailsView: View {
    let inspector: ItemInspector
    let formatter: SizeFormatter

    var body: some View {
        if let details = inspector.details {
            VStack(spacing: 0) {
                previewArea
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        heading(details)
                        facts(details)
                        actions
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.right",
                description: Text("Select a file or folder to see what it is.")
            )
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewArea: some View {
        Group {
            switch inspector.preview {
            case .ready(let url):
                // Rebuilt per item rather than reused. Quick Look holds render state for whatever
                // it was last given, and a stale panel behind a new file is worse than a reload.
                QuickLookPreview(url: url)
                    .id(url)
            case .loading:
                // Delay-then-show, so an item that resolves immediately never flashes a spinner
                // on its way to being drawn (Principle III).
                if inspector.activity.isVisible {
                    ProgressView()
                } else {
                    Color.clear
                }
            case .unavailable(let reason):
                unavailable(reason)
            case nil:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
        .background(.quaternary.opacity(0.3))
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No preview. \(reason)")
    }

    // MARK: - Facts

    private func heading(_ details: ItemDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(details.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(details.typeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func facts(_ details: ItemDetails) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
            fact("Size", size(details))

            if details.kind != .file {
                fact("Contains", "\(details.itemCount - 1) items")
            }
            if details.countedElsewhere {
                fact("Shared", "The same data is counted under another name.")
            }

            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)

            fact("Where", (details.path as NSString).deletingLastPathComponent, wraps: true)

            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)

            fact("Created", when(details.created))
            fact("Modified", when(details.modified))
            fact("Last opened", when(details.accessed))
        }
    }

    /// Both figures whenever they disagree, because a file that occupies less than it contains is
    /// sparse or compressed, and hiding that reads as the scanner getting the number wrong.
    private func size(_ details: ItemDetails) -> String {
        let occupied = formatter.string(from: details.occupiedBytes)
        guard details.sizesDiffer, let logical = details.logicalBytes else { return occupied }
        return "\(occupied) on disk · \(formatter.string(from: logical)) of contents"
    }

    private func when(_ date: Date) -> String {
        date == .distantPast ? "Unknown" : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Values are selectable throughout. Copying a path out of here is the natural next step after
    /// reading it, and there is nothing on this panel worth withholding from the clipboard.
    private func fact(_ label: String, _ value: String, wraps: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(wraps ? 4 : 2)
                .truncationMode(.middle)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label). \(value)")
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Button("Reveal in Finder") { inspector.reveal() }
            Button("Open") { inspector.open() }
                .help("Open in whichever application claims this kind of file")
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}
