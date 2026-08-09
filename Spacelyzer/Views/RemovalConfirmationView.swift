import SwiftUI

/// Everything that is about to happen, before any of it does (FR-052, FR-054, FR-055).
///
/// The list is the point. Nothing here is a count standing in for a list someone might want to
/// see; if the user is being asked to agree to a removal, they are shown what they are agreeing
/// to.
struct RemovalConfirmationView: View {
    let plan: RemovalPlan
    let formatter: SizeFormatter
    @Binding var deletePermanently: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// Beyond this the list scrolls rather than the sheet growing past the screen.
    private static let listHeight: CGFloat = 200

    private var isPermanent: Bool { deletePermanently || !plan.trashAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !plan.isEmpty { permittedList }
            if plan.hasRefusals { refusedList }
            disposition
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if !plan.isEmpty {
                Text("\(formatter.string(from: plan.totalReclaimable)) will be reclaimed.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if plan.isEmpty {
            return "Nothing here can be removed"
        }
        let count = plan.permitted.count
        return count == 1 ? "Remove 1 item?" : "Remove \(count) items?"
    }

    private var permittedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan.permitted, id: \.url) { item in
                    HStack(spacing: 8) {
                        Text(item.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(formatter.string(from: item.size))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .help(item.url.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.listHeight)
    }

    /// Shown alongside what will happen, not instead of it. A refusal never blocks the rest of the
    /// selection, so the user needs both halves to know what they are agreeing to.
    private var refusedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                plan.refused.count == 1
                    ? "1 item will be left alone" : "\(plan.refused.count) items will be left alone",
                systemImage: "hand.raised"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.refused, id: \.url) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.refusal.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help(item.url.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    @ViewBuilder
    private var disposition: some View {
        if plan.isEmpty {
            EmptyView()
        } else if plan.trashAvailable {
            VStack(alignment: .leading, spacing: 6) {
                // An explicit, separate choice, not a variant of the confirm button. Deleting for
                // good is a different act from putting something in the Trash, and it is only
                // reachable by saying so first (FR-054).
                Toggle("Delete permanently instead of moving to the Trash", isOn: $deletePermanently)

                if deletePermanently {
                    Label(
                        "This cannot be undone. These items will not be in the Trash afterwards.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
        } else {
            // Determined before the user was told anything, so the app never promises a Trash the
            // volume does not have (FR-053).
            Label(
                "This volume has no Trash, so these will be deleted permanently and cannot be undone.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            if !plan.isEmpty {
                Button(isPermanent ? "Delete Permanently" : "Move to Trash", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    // Deliberately not the default action. Return should not destroy anything.
                    .tint(isPermanent ? .red : .accentColor)
            }
        }
    }
}

/// What a finished batch actually did (FR-056).
struct RemovalSummaryView: View {
    let summary: RemovalSummary
    let undoAvailability: UndoAvailability
    let undoSummary: UndoSummary?
    let isUndoing: Bool
    let formatter: SizeFormatter
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.headline)

            if summary.wasCancelled {
                Text("Stopped part way. What had already been removed stayed removed.")
                    .foregroundStyle(.secondary)
            }

            if !summary.failures.isEmpty {
                failures
            }

            if let undoSummary {
                restoration(undoSummary)
            } else if case let .unavailable(reason) = undoAvailability {
                Label(reason.explanation, systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if undoAvailability.isAvailable, undoSummary == nil {
                    Button("Put Back", action: onUndo)
                        .disabled(isUndoing)
                }
                if isUndoing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var headline: String {
        let count = summary.removed.count
        let verb = summary.disposition == .trash ? "moved to the Trash" : "deleted"
        if count == 0 { return "Nothing was removed" }
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(items) \(verb), \(formatter.string(from: summary.bytesFreed)) reclaimed"
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                summary.failures.count == 1
                    ? "1 item could not be removed"
                    : "\(summary.failures.count) items could not be removed",
                systemImage: "exclamationmark.circle"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.failures, id: \.path) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((failure.path as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(failure.reason.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help(failure.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    /// Reports what came back, and says plainly when that was not all of it. Rounding a partial
    /// restoration up to a success is exactly what FR-060 forbids.
    private func restoration(_ undo: UndoSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if undo.wasComplete {
                Label("Everything was put back.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label(
                    undo.restored.isEmpty
                        ? "Nothing could be put back."
                        : "\(undo.restored.count) of \(undo.restored.count + undo.failures.count) were put back.",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)

                ForEach(Array(Set(undo.failures.map(\.reason.explanation))), id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

/// Progress while a batch runs, in the pane rather than over the window.
///
/// Not a modal. Principle III forbids work that blocks its own cancellation, and a sheet that
/// locks the window until removal finishes does exactly that (FR-071).
struct RemovalProgressView: View {
    let removed: Int
    let planned: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(removed), total: Double(max(1, planned)))
                .progressViewStyle(.linear)
            Text("\(removed) of \(planned)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Stop", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
