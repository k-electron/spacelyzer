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
    /// Held back until the user has seen what a scan of it will miss (FR-018).
    @State private var pendingScan: URL?
    @State private var showingExclusions = false
    @State private var coordinator = LayoutCoordinator()
    @State private var trailingTab: TrailingTab = .treemap
    @State private var coloring: TreemapColoring = .folder
    @State private var selection = SelectionCoordinator()
    @State private var filters = FilterCoordinator()
    @State private var inspector = ItemInspector()
    /// Closed until asked for. It answers a question about one item, which is not the question
    /// anyone opens the app with, and it costs a Quick Look render for whatever is selected.
    @State private var showingDetails = false
    /// The list in force when the displayed result was produced, so a later change to it can be
    /// recognised as making that result stale rather than merely old (FR-013).
    @State private var scannedWithExclusions: [URL] = []

    private let formatter = SizeFormatter()

    private var recentLocations: RecentLocations {
        RecentLocations(context: modelContext)
    }

    private var exclusionRules: ExclusionRules {
        ExclusionRules(context: modelContext)
    }

    private var resultIsStale: Bool {
        controller.root != nil
            && exclusionRules.resultIsStale(scannedWith: scannedWithExclusions)
    }

    /// What the window opens at, and the figure the split below is a third of.
    static let defaultWindowSize = CGSize(width: 1280, height: 820)

    var body: some View {
        // Not HSplitView. That one ignores an ideal width outright — it divided the window in half
        // whatever the panes asked for — and it reports an intrinsic size that overrode the
        // window's default size as well. This honours both, which is what puts the divider at a
        // third and opens the window at a size somebody chose.
        NavigationSplitView {
            // A third to start with. The tree is names and numbers and stops being more readable
            // past a point, whereas the picture keeps using whatever it is given.
            leadingPane
                .navigationSplitViewColumnWidth(
                    min: 300,
                    ideal: Self.defaultWindowSize.width / 3,
                    max: 900
                )
        } detail: {
            // No stated width. The detail column takes whatever is left, which is the whole point
            // of it; giving it an ideal turned that ideal into a floor, and the floor plus the
            // sidebar's became a window minimum nothing could shrink past. Widening the details
            // panel then had nowhere to take the room from and grew the window instead.
            trailingPane
        }
        // Balanced keeps the tree a column beside the picture. The automatic style would let it
        // slide over the top as an overlay, which is the arrangement this pane exists not to be.
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: 560)
        // Beside the views rather than replacing one of them. Deciding what a four-gigabyte file
        // is means looking at it and at where it sits in the scan at the same time.
        .inspector(isPresented: $showingDetails) {
            DetailsPane(
                inspector: inspector,
                selection: selection,
                formatter: formatter,
                inspect: { inspectSelection($0) }
            )
            // One fixed width, so the panel cannot be dragged. Given a range it could be, and
            // dragging it widened the window instead of narrowing the picture — measured at every
            // step, and it happened with an empty detail column and with nothing greedy in the
            // panel, so it is how this inspector resizes rather than anything it was holding.
            // A panel that cannot be dragged is a normal thing on this platform; one that drags
            // the window out from under you is not.
            .inspectorColumnWidth(320)
        }
        .toolbar { toolbarContent }
        // Applied at the root so the whole window follows, including sheets and popovers.
        .preferredColorScheme(appearance.colorScheme)
        .sheet(isPresented: $showingExclusions) {
            ExclusionsSheet(
                rules: exclusionRules,
                scanRoot: controller.rootURL,
                chooseFolder: { broker.chooseFolder() }
            )
        }
        .task {
            volumes = broker.mountedVolumes()
            recents = recentLocations.all()
            appearance = Preferences.current(in: modelContext).appearance
        }
        // A grant made in System Settings only becomes visible on the way back into the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            broker.refreshAccessState()
        }
        // One result, handed to both views, so they cannot describe different subsets (FR-042).
        .onChange(of: filters.result) { _, result in
            coordinator.apply(retained: result?.retained)
        }
        // Closing the panel has to stop the work as well as hide it, and opening it has to pick up
        // whatever was selected in the meantime. `showingDetails` is local state, so reading it
        // here costs nothing; the selection is watched inside the pane for the opposite reason.
        .onChange(of: showingDetails) { _, shown in
            if shown {
                inspectSelection(selection.selectedPath)
            } else {
                inspector.clear()
            }
        }
        .onChange(of: controller.state) { _, state in
            guard let url = controller.rootURL else { return }

            // Partial results are worth drawing, so a cancelled scan gets a picture too.
            if state == .completed || state == .cancelled, let root = controller.root {
                coordinator.present(root: root, path: url.standardizedFileURL.path)
                filters.present(root: root, path: url.standardizedFileURL.path)
            }

            // Recorded only once a scan has actually produced a total worth returning to.
            guard state == .completed else { return }
            recentLocations.record(url: url, measuredTotal: controller.totals.measuredBytes)
            recents = recentLocations.all()
        }
    }

    private enum TrailingTab: Hashable {
        case treemap
        case kinds
        case totals
    }

    /// One way in, so nothing can start a scan without first showing what it will miss.
    private func beginScan(_ url: URL) {
        let atRisk = broker.protectedLocationsAtRisk(under: url)
        if atRisk.isEmpty {
            startScan(url)
        } else {
            pendingScan = url
        }
    }

    /// Drilling changes what the treemap can represent, so the selection has to be reconciled
    /// with the new root rather than left pointing somewhere invisible (FR-036).
    private func drill(into node: TreemapNode) {
        coordinator.drill(into: node)
        resolveSelectionAgainstDisplayedRoot()
    }

    private func resolveSelectionAgainstDisplayedRoot() {
        guard let rootPath = coordinator.displayedRootPath else { return }
        selection.resolve(withinRoot: rootPath)
    }

    private func inspectSelection(_ path: String?) {
        guard showingDetails else { return }
        guard let path, let root = controller.root, let url = controller.rootURL else {
            inspector.clear()
            return
        }
        inspector.inspect(path: path, in: root, rootPath: url.standardizedFileURL.path)
    }

    private func startScan(_ url: URL) {
        pendingScan = nil
        broker.acknowledgeGrant()
        coordinator.clear()
        selection.clear()
        // Whatever was being looked at belongs to the analysis being replaced, and the panel is
        // the wrong thing to be watching while a new one runs.
        showingDetails = false
        inspector.clear()
        filters.clearScan()
        scannedWithExclusions = exclusionRules.excludedURLs()
        controller.scan(root: url, excluding: scannedWithExclusions)
    }

    @ViewBuilder
    private var leadingPane: some View {
        VStack(spacing: 0) {
            locationHeader

            if let pending = pendingScan {
                AccessWarningView(
                    locations: broker.protectedLocationsAtRisk(under: pending),
                    onOpenSettings: { broker.openFullDiskAccessSettings() },
                    onDismiss: { startScan(pending) }
                )
                .padding(8)
            }

            if broker.accessWasJustGranted, controller.rootURL != nil {
                AccessGrantedBanner(
                    onRescan: { if let url = controller.rootURL { startScan(url) } },
                    onDismiss: { broker.acknowledgeGrant() }
                )
                .padding(8)
            }

            if resultIsStale {
                StaleResultBanner(onRescan: { if let url = controller.rootURL { startScan(url) } })
                    .padding(8)
            }

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
                FilterBarView(
                    filter: filters.filter,
                    result: filters.result,
                    isWorking: filters.activity.isVisible,
                    formatter: formatter,
                    onChange: { filters.update($0) }
                )
                Divider()

                if filters.matchedNothing {
                    FilterEmptyStateView(onClear: { filters.clearFilter() })
                } else {
                    HierarchyOutlineView(
                        root: root,
                        rootPath: controller.rootURL?.standardizedFileURL.path ?? "",
                        formatter: formatter,
                        sortOrder: sortOrder,
                        selection: selection,
                        retained: filters.result?.retained
                    )
                }
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

    /// What is being shown, and the way to go somewhere else, pinned above the tree rather than
    /// scrolling away with it. Starting a new scan is the most common thing to want next, so it
    /// belongs beside the results rather than in the toolbar across the window.
    @ViewBuilder
    private var locationHeader: some View {
        if let url = controller.rootURL {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(url.standardizedFileURL.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(url.standardizedFileURL.path)

                    Spacer(minLength: 8)

                    Button {
                        controller.rescan(excluding: scannedWithExclusions)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(controller.isRunning)
                    .help("Analyze this location again")

                    Button {
                        if let picked = broker.chooseFolder() { beginScan(picked) }
                    } label: {
                        Label("New Analysis…", systemImage: "folder.badge.magnifyingglass")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()
            }
            .background(.bar)
        }
    }

    private var startPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Choose something to analyze") {
                    ForEach(volumes) { volume in
                        Button {
                            beginScan(volume.url)
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
                            beginScan(url)
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
                    beginScan(url)
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

    private var trailingPane: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $trailingTab) {
                Text("Treemap").tag(TrailingTab.treemap)
                Text("Kinds").tag(TrailingTab.kinds)
                Text("Totals").tag(TrailingTab.totals)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch trailingTab {
            case .treemap: treemapPane
            case .kinds: kindsPane
            case .totals: totalsPane
            }
        }
    }

    @ViewBuilder
    private var treemapPane: some View {
        if coordinator.hasContent {
            VStack(spacing: 0) {
                HStack {
                    TreemapTrailView(trail: coordinator.trail) { depth in
                        coordinator.navigate(toDepth: depth)
                        resolveSelectionAgainstDisplayedRoot()
                    }
                    Picker("Colour", selection: $coloring) {
                        ForEach(TreemapColoring.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .padding(.trailing, 8)
                    .help("What the colours stand for")
                }
                Divider()
                TreemapCanvas(
                    snapshot: coordinator.snapshot,
                    formatter: formatter,
                    coloring: coloring,
                    isRecomputing: coordinator.activity.isVisible,
                    selection: selection,
                    onDrill: { drill(into: $0) },
                    onResize: { coordinator.resize(to: $0) }
                )
                Divider()
                TreemapLegendView(entries: legendEntries, caption: coloring.explanation)
            }
        } else {
            ContentUnavailableView(
                "Nothing analyzed yet",
                systemImage: "square.grid.3x3",
                description: Text("Analyze a folder or a volume and it will be drawn here.")
            )
        }
    }

    private var kindsPane: some View {
        CategoryBreakdownView(
            totals: filters.breakdown,
            selected: filters.filter.categories,
            formatter: formatter,
            onSelect: { filters.toggleCategory($0) }
        )
    }

    @ViewBuilder
    private var totalsPane: some View {
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
                "No totals yet",
                systemImage: "chart.pie",
                description: Text("Finish a scan to see how it squares with the volume.")
            )
        }
    }

    /// Only what is actually drawn, so the legend never lists a colour that is not on screen.
    private var legendEntries: [TreemapLegendView.Entry] {
        let drawn = coordinator.layout.nodes.filter { !$0.isRemainder }

        switch coloring {
        case .category:
            let present = Set(drawn.map(\.category))
            return FileCategory.allCases.filter(present.contains).map {
                TreemapLegendView.Entry(id: $0.label, label: $0.label, color: $0.color)
            }
        case .folder:
            // Named from the depth-one rectangles, which are exactly the branches, and ordered
            // by branch so the legend reads in the same order the layout placed them.
            return drawn
                .filter { $0.depth == 1 }
                .sorted { $0.branch < $1.branch }
                .map {
                    TreemapLegendView.Entry(
                        id: $0.path,
                        label: $0.name,
                        color: TreemapColoring.branchColor($0.branch)
                    )
                }
        case .depth:
            return []
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
                showingExclusions = true
            } label: {
                Label("Exclusions", systemImage: "minus.circle")
            }
            .help("Choose folders to leave out of scans")
        }
        ToolbarItem {
            Button {
                showingDetails.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(showingDetails ? "Hide the details panel" : "Show the details panel")
        }
        // Choosing somewhere to scan and rescanning where you are both live in the header above
        // the tree now. They act on what the left pane is showing, so putting them across the
        // window from it only made them harder to find.
    }
}
