import SwiftData
import SwiftUI

/// Hierarchy on the leading side, treemap on the trailing side, with a divider the user can move
/// (FR-026). The treemap itself arrives in User Story 3; until then the trailing side says so
/// rather than presenting an unexplained empty pane.
struct MainSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var controller = ScanController()
    @State private var broker = AccessBroker()
    @State private var sortOrder: SortOrder = .size
    @State private var volumes: [VolumeDescriptor] = []
    @State private var recents: [RecentLocation] = []
    @State private var appearance: AppearancePreference = .system

    private let formatter = SizeFormatter()

    private var recentLocations: RecentLocations {
        RecentLocations(context: modelContext)
    }

    var body: some View {
        HSplitView {
            leadingPane
                .frame(minWidth: 320, idealWidth: 420, maxHeight: .infinity)
            trailingPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { toolbarContent }
        // Applied at the root so the whole window follows, including sheets and popovers.
        .preferredColorScheme(appearance.colorScheme)
        .task {
            volumes = broker.mountedVolumes()
            recents = recentLocations.all()
            appearance = Preferences.current(in: modelContext).appearance
        }
        .onChange(of: controller.state) { _, state in
            // Recorded only once a scan has actually produced a total worth returning to.
            guard state == .completed, let url = controller.rootURL else { return }
            recentLocations.record(url: url, measuredTotal: controller.totals.measuredBytes)
            recents = recentLocations.all()
        }
    }

    @ViewBuilder
    private var leadingPane: some View {
        VStack(spacing: 0) {
            // Driven by the delay-then-show indicator rather than by `isRunning`, so a scan that
            // finishes quickly never flashes a progress panel (FR-069).
            if controller.activity.isVisible {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Choose something to measure") {
                    ForEach(volumes) { volume in
                        Button {
                            controller.scan(root: volume.url)
                        } label: {
                            row(
                                symbol: "internaldrive",
                                title: volume.name,
                                detail: "\(formatter.string(from: volume.availableCapacity)) free of \(formatter.string(from: volume.totalCapacity))"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button("Choose Folder…") {
                        if let url = broker.chooseFolder() {
                            controller.scan(root: url)
                        }
                    }
                    .padding(.top, 4)
                }

                if !recents.isEmpty {
                    section("Recent") {
                        ForEach(recents, id: \.persistentModelID) { entry in
                            recentRow(entry)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func recentRow(_ entry: RecentLocation) -> some View {
        let available = recentLocations.isAvailable(entry)

        HStack {
            Button {
                // Resolved through the bookmark first, so a folder that moved is still found.
                if let url = recentLocations.resolve(entry) {
                    controller.scan(root: url)
                }
            } label: {
                row(
                    symbol: available ? "clock.arrow.circlepath" : "questionmark.folder",
                    title: (entry.displayPath as NSString).lastPathComponent,
                    detail: available
                        ? "\(formatter.string(from: entry.lastMeasuredTotal)) · \(entry.lastScannedAt.formatted(.relative(presentation: .named)))"
                        : "Unavailable"
                )
            }
            .buttonStyle(.plain)
            .disabled(!available)

            Button {
                recentLocations.forget(entry)
                recents = recentLocations.all()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Forget this location")
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { appearance },
            set: { newValue in
                appearance = newValue
                Preferences.current(in: modelContext).appearance = newValue
                try? modelContext.save()
            }
        )
    }

    @ViewBuilder
    private var trailingPane: some View {
        if let accounting = controller.accounting {
            VolumeAccountingView(accounting: accounting, formatter: formatter)
        } else if controller.accountingActivity.isVisible {
            VStack(spacing: 10) {
                ProgressView()
                Text(controller.accountingActivity.message ?? "Checking the totals")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Treemap",
                systemImage: "square.grid.3x3",
                description: Text("The proportional view arrives with User Story 3.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            // Kept in the toolbar rather than behind Settings: someone whose Mac is in dark mode
            // should be able to see how to leave it without going hunting.
            Menu {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppearancePreference.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Appearance", systemImage: appearance.symbol)
            }
            .help("Switch between light, dark, and the system setting")
        }
        ToolbarItem {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        ToolbarItem {
            Button {
                controller.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(controller.rootURL == nil || controller.isRunning)
            .help("Measure this location again")
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
