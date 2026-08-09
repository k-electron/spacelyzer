import SwiftUI

/// Reviewing and editing the exclusion list, which FR-011 requires be possible at all.
struct ExclusionsSheet: View {
    let rules: ExclusionRules
    let scanRoot: URL?
    let chooseFolder: () -> URL?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ExclusionRule] = []
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded Folders")
                .font(.title3.weight(.semibold))

            Text("These are skipped during a scan. Their contents are reported as excluded rather than counted, so the totals still add up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if entries.isEmpty {
                Text("Nothing is excluded.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                List(entries, id: \.persistentModelID) { entry in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            rules.remove(entry)
                            reload()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop excluding this folder")
                    }
                }
                .frame(minHeight: 160)
            }

            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Add Folder…") { add() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: reload)
    }

    private func add() {
        guard let url = chooseFolder() else { return }
        do {
            try rules.add(url, scanRoot: scanRoot)
            refusal = nil
            reload()
        } catch let error as ExclusionRefusal {
            // Shown rather than swallowed: a refusal the user cannot see is indistinguishable
            // from a broken button (FR-012).
            refusal = error.explanation
        } catch {
            refusal = "That folder could not be excluded."
        }
    }

    private func reload() {
        entries = rules.all()
    }
}

/// Says that the displayed result predates the current exclusion list, and offers the rescan that
/// would fix it (FR-013).
struct StaleResultBanner: View {
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("The exclusion list changed after this scan ran.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Rescan", action: onRescan)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
