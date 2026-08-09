import SwiftData
import SwiftUI

/// What has been removed, when, and whether it can still be brought back (FR-061).
///
/// Only paths and sizes were ever recorded, so clearing this leaves no account of what was once on
/// the disk — which is the point of offering a way to clear it.
struct RemovalHistoryView: View {
    let history: RemovalHistory
    let formatter: SizeFormatter
    let onDismiss: () -> Void

    @State private var entries: [RemovalHistoryEntry] = []
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing removed yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Removals you make will be listed here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(entries, id: \.persistentModelID) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .onAppear { entries = history.all() }
        .confirmationDialog(
            "Clear the removal history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                history.clear()
                entries = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Worth saying: clearing looks destructive and is not, and the one thing it does cost
            // is the ability to put the last batch back through the app.
            Text(
                "This removes the record only. Nothing comes back out of the Trash, and nothing "
                    + "further is deleted."
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Removal History")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button("Clear…") { confirmingClear = true }
                .disabled(entries.isEmpty)
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ entry: RemovalHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.performedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(formatter.string(from: entry.bytesFreed))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(describe(entry))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reason = entry.undoBlockedReason, entry.undoState != .undone {
                Text(reason.explanation)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.performedAt.formatted(date: .abbreviated, time: .shortened)), "
                + "\(describe(entry)), \(formatter.string(from: entry.bytesFreed))"
        )
    }

    private func describe(_ entry: RemovalHistoryEntry) -> String {
        var parts: [String] = [
            entry.itemCount == 1 ? "1 item" : "\(entry.itemCount) items",
            entry.disposition == .trash ? "moved to the Trash" : "deleted permanently",
        ]
        if entry.failureCount > 0 {
            parts.append(
                entry.failureCount == 1 ? "1 failed" : "\(entry.failureCount) failed"
            )
        }
        if entry.wasCancelled { parts.append("stopped part way") }
        switch entry.undoState {
        case .undoable: break
        case .undone: parts.append("put back")
        case .unrestorable: parts.append("cannot be put back")
        }
        return parts.joined(separator: " · ")
    }
}
