import AppKit
import SwiftUI

/// The material a sidebar is drawn on, which SwiftUI exposes no name for.
///
/// Worth reaching to AppKit for. The details panel sits opposite the tree across the same window,
/// and two flanking panes that are almost but not quite the same colour look like an oversight
/// rather than a choice.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Matches the tree, which also goes flat when the window loses focus.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The details pane, and the only place outside the two drawing views that watches the selection.
///
/// Watching it from `MainSplitView` instead made every click invalidate that whole view, and with
/// it both panes, the treemap legend, and a fetch of the exclusion list. None of those depend on
/// what is selected, and on a large scan rebuilding them is the most expensive thing the app does.
/// Read here, a click re-evaluates this pane and nothing else.
struct DetailsPane: View {
    let inspector: ItemInspector
    let selection: SelectionCoordinator
    let formatter: SizeFormatter
    /// Called with whatever is selected, on appearing as well as on change, so a pane that was
    /// closed while the selection moved catches up when it opens.
    let inspect: (String?) -> Void

    var body: some View {
        ItemDetailsView(inspector: inspector, formatter: formatter)
            .onChange(of: selection.selectedPath, initial: true) { _, path in
                inspect(path)
            }
    }
}

/// What the selected item is, above what is known about it (FR-045 through FR-050).
///
/// The preview sits at the top because it answers the question fastest. A name like
/// `archive_final_v2` tells nobody anything; a thumbnail of it usually settles the matter before
/// the dates below have been read.
struct ItemDetailsView: View {
    let inspector: ItemInspector
    let formatter: SizeFormatter

    var body: some View {
        Group {
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
        // Clipped, so nothing hosted here can draw outside the column, but left to the system to
        // colour. Painting the whole panel opaque covered the smear that came of it overlapping
        // the treemap, and once that overlap was fixed properly all the paint still did was carry
        // the panel up into the toolbar as a block of its own. Only the preview sits on a surface
        // of its own, because that is the part with a foreign view in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            // Mounted once and handed each item in turn, including nothing at all. Taking it out
            // of the view tree between selections built and closed a preview view on every click,
            // and closing one tears down its connection to the process that renders previews —
            // which is felt immediately when clicking around the treemap.
            QuickLookPreview(url: readyURL)
                .opacity(readyURL == nil ? 0 : 1)

            switch inspector.preview {
            case .loading:
                // Delay-then-show, so an item that resolves immediately never flashes a spinner
                // on its way to being drawn (Principle III).
                if inspector.activity.isVisible {
                    ProgressView()
                }
            case .unavailable(let reason):
                unavailable(reason)
            case .ready, nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipped()
    }

    private var readyURL: URL? {
        guard case .ready(let url) = inspector.preview else { return nil }
        return url
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
            // Truncated rather than wrapped. A long name with no spaces in it is one word, and a
            // word that cannot be broken is a width the panel would otherwise have to find.
            Text(details.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(details.typeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
