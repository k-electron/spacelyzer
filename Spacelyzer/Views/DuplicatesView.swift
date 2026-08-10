import SwiftUI

/// Runs the duplicate search and holds what it found.
///
/// Marks live on the sets themselves, so this passes requests through rather than deciding them.
/// FR-065 is not a rule this coordinator remembers to apply; it is one it cannot get around.
@MainActor
@Observable
final class DuplicatesCoordinator {
    private(set) var sets: [DuplicateSet] = []
    private(set) var report: DuplicateReport?
    private(set) var isSearching = false
    private(set) var progress: DuplicateProgress?

    let activity = ActivityIndicator()

    private var work: Task<Void, Never>?

    var markedCount: Int { sets.reduce(0) { $0 + $1.marked.count } }
    var markedSize: Int64 { sets.reduce(0) { $0 + $1.markedSize } }
    var hasRun: Bool { report != nil }

    func search(in root: ScannedItem, rootPath: String, minimumSize: Int64) {
        cancel()

        isSearching = true
        progress = nil
        sets = []
        report = nil
        activity.begin("Comparing files")

        var finder = DuplicateFinder()
        finder.minimumSize = minimumSize

        work = Task { [finder] in
            defer {
                self.isSearching = false
                self.progress = nil
                self.activity.end()
            }
            for await event in finder.find(in: root, rootPath: rootPath) {
                switch event {
                case let .progress(progress):
                    self.progress = progress
                case let .finished(report):
                    self.sets = report.sets
                    self.report = report
                }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// Cleared when a new analysis starts. Sets name files by path, and those paths describe the
    /// scan they came from.
    func clearScan() {
        cancel()
        sets = []
        report = nil
        progress = nil
        activity.end()
    }

    func toggle(_ path: String, inSetWith id: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        if sets[index].isMarked(path) {
            sets[index].unmark(path)
        } else {
            sets[index].mark(path)
        }
    }

    func markAllButOne(inSetWith id: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].markAllButOne()
    }

    func unmarkAll(inSetWith id: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].unmarkAll()
    }

    /// Everything marked across every set, as one batch (FR-051).
    func removalCandidates() -> [RemovalCandidate] {
        sets.flatMap { $0.removalCandidates() }
    }

    /// Takes removed copies out of the sets, and drops any set left with a single copy since it
    /// is not a duplicate of anything any more.
    func forget(paths: [String]) {
        let gone = Set(paths)
        sets = sets.compactMap { $0.removing(gone) }
    }
}

/// Files stored more than once, ranked by what each set would give back (FR-064).
struct DuplicatesView: View {
    let coordinator: DuplicatesCoordinator
    let formatter: SizeFormatter
    let threshold: Int64
    let canSearch: Bool
    let onSearch: () -> Void
    let onCancel: () -> Void
    let onChangeThreshold: (Int64) -> Void
    let onRemoveMarked: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if coordinator.isSearching {
                    Button("Stop", action: onCancel)
                } else {
                    Button("Find Duplicates", action: onSearch)
                        .disabled(!canSearch)
                }

                Picker("Ignore files under", selection: thresholdBinding) {
                    ForEach(Self.thresholds, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(coordinator.isSearching)

                Spacer(minLength: 8)

                if coordinator.markedCount > 0 {
                    Button("Remove \(coordinator.markedCount)", action: onRemoveMarked)
                        .help("Move the ticked copies to the Trash")
                }
            }

            if coordinator.isSearching, let progress = coordinator.progress {
                stageProgress(progress)
            }
        }
        .padding(8)
    }

    private func stageProgress(_ progress: DuplicateProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
            Text(progress.stage.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(progress.filesDone) of \(progress.filesTotal)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var thresholdBinding: Binding<Int64> {
        Binding(get: { threshold }, set: { onChangeThreshold($0) })
    }

    /// Offered as a few sensible sizes rather than a free number, including nothing at all for
    /// anyone who does mean every file.
    static let thresholds: [(label: String, value: Int64)] = [
        ("Ignore files under 1 MB", 1_000_000),
        ("Ignore files under 10 MB", 10_000_000),
        ("Ignore files under 100 MB", 100_000_000),
        ("Compare every file", 0),
    ]

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if coordinator.isSearching, coordinator.sets.isEmpty {
            ContentUnavailableView(
                "Looking for duplicates",
                systemImage: "doc.on.doc",
                description: Text("Files are compared by their contents, so this reads them.")
            )
        } else if coordinator.sets.isEmpty, let report = coordinator.report {
            emptyResult(report)
        } else if coordinator.sets.isEmpty {
            ContentUnavailableView(
                "No search yet",
                systemImage: "doc.on.doc",
                description: Text(
                    canSearch
                        ? "Find duplicates to see files whose contents are identical."
                        : "Analyse a location first, then its files can be compared."
                )
            )
        } else {
            list
        }
    }

    /// Says what it looked at, because "no duplicates" and "nothing was eligible" are different
    /// answers and the threshold is the usual reason for the second.
    private func emptyResult(_ report: DuplicateReport) -> some View {
        ContentUnavailableView(
            "No duplicates",
            systemImage: "checkmark.circle",
            description: Text(
                report.considered == 0
                    ? "None of the files were big enough to compare. \(report.belowThreshold) "
                        + "were under the size limit."
                    : "\(report.considered) files were compared and none had the same contents "
                        + "as another."
            )
        )
    }

    private var list: some View {
        List {
            Section {
                ForEach(coordinator.sets) { set in
                    DuplicateSetRow(
                        set: set,
                        formatter: formatter,
                        onToggle: { coordinator.toggle($0, inSetWith: set.id) },
                        onMarkAllButOne: { coordinator.markAllButOne(inSetWith: set.id) },
                        onUnmarkAll: { coordinator.unmarkAll(inSetWith: set.id) }
                    )
                }
            } header: {
                summary
            }
        }
        .listStyle(.inset)
    }

    private var summary: some View {
        HStack {
            Text(
                coordinator.sets.count == 1
                    ? "1 set of duplicates" : "\(coordinator.sets.count) sets of duplicates"
            )
            Spacer()
            if coordinator.markedCount > 0 {
                Text("\(formatter.string(from: coordinator.markedSize)) ticked")
                    .foregroundStyle(.secondary)
            } else {
                let total = coordinator.sets.reduce(0) { $0 + $1.recoverableSize }
                Text("\(formatter.string(from: total)) recoverable")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One set: what a copy costs, how many there are, and which of them are to go.
private struct DuplicateSetRow: View {
    let set: DuplicateSet
    let formatter: SizeFormatter
    let onToggle: (String) -> Void
    let onMarkAllButOne: () -> Void
    let onUnmarkAll: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(set.copies) { copy in
                copyRow(copy)
            }
            HStack {
                Button("Keep the first, remove the rest", action: onMarkAllButOne)
                if !set.marked.isEmpty {
                    Button("Clear", action: onUnmarkAll)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 24)
        } label: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
            Text(set.copies.first?.name ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(set.copies.count) copies")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Text(formatter.string(from: set.recoverableSize))
                .monospacedDigit()
                .help("What removing all but one copy would give back")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(set.copies.first?.name ?? "Duplicate"), \(set.copies.count) copies, "
                + "\(formatter.string(from: set.recoverableSize)) recoverable"
        )
    }

    private func copyRow(_ copy: DuplicateCopy) -> some View {
        let refused = set.refusal(forMarking: copy.path)
        let marked = set.isMarked(copy.path)

        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { marked }, set: { _ in onToggle(copy.path) })) {
                Text(copy.enclosingFolder)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(.callout)
            }
            // Refused only when ticking it would leave the set with nothing. The one copy that
            // has to stay is the whole point of the set, so it reads as protected rather than
            // as an option that happens to be off.
            .disabled(!marked && refused != nil)
            .help(marked ? "" : refused?.explanation ?? "")

            Spacer(minLength: 8)

            if !marked, refused == .wouldLeaveNoCopy {
                Text("kept")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
    }
}
