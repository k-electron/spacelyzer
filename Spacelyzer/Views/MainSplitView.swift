import SwiftUI

/// Hierarchy on the leading side, treemap on the trailing side, with a divider the user can move
/// (FR-026). The treemap itself arrives in User Story 3; until then the trailing side says so
/// rather than presenting an unexplained empty pane.
struct MainSplitView: View {
    @State private var controller = ScanController()
    @State private var broker = AccessBroker()
    @State private var sortOrder: SortOrder = .size
    @State private var volumes: [VolumeDescriptor] = []

    private let formatter = SizeFormatter()

    var body: some View {
        HSplitView {
            leadingPane
                .frame(minWidth: 320, idealWidth: 420, maxHeight: .infinity)
            trailingPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { toolbarContent }
        .task { volumes = broker.mountedVolumes() }
    }

    @ViewBuilder
    private var leadingPane: some View {
        VStack(spacing: 0) {
            if controller.isRunning {
                ScanProgressView(
                    totals: controller.totals,
                    currentPath: controller.currentPath,
                    formatter: formatter,
                    onCancel: { controller.cancel() }
                )
                .padding(8)
            }

            if controller.resultsAreIncomplete, controller.root != nil {
                Label("These results are incomplete", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            if let root = controller.root {
                HierarchyOutlineView(root: root, formatter: formatter, sortOrder: sortOrder)
            } else if !controller.isRunning {
                startPane
            } else {
                Spacer()
            }

            if !controller.skipped.isEmpty {
                Divider()
                SkippedLocationsView(skipped: controller.skipped)
                    .padding(.vertical, 6)
            }
        }
    }

    private var startPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose something to measure")
                .font(.headline)

            ForEach(volumes) { volume in
                Button {
                    controller.scan(root: volume.url)
                } label: {
                    HStack {
                        Image(systemName: "internaldrive")
                        VStack(alignment: .leading) {
                            Text(volume.name)
                            Text("\(formatter.string(from: volume.availableCapacity)) free of \(formatter.string(from: volume.totalCapacity))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Button("Choose Folder…") {
                if let url = broker.chooseFolder() {
                    controller.scan(root: url)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailingPane: some View {
        ContentUnavailableView(
            "Treemap",
            systemImage: "square.grid.3x3",
            description: Text("The proportional view arrives with User Story 3.")
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        ToolbarItem {
            Button {
                if let url = broker.chooseFolder() {
                    controller.scan(root: url)
                }
            } label: {
                Label("Scan Folder", systemImage: "folder.badge.magnifyingglass")
            }
        }
    }
}
