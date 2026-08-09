import SwiftUI

/// Names the protected locations a scan will miss, before its results are shown (FR-018).
///
/// The tone is deliberate. The constitution forbids presenting Full Disk Access as required, so
/// this states what will be missing and how to change that, and leaves scanning available either
/// way.
struct AccessWarningView: View {
    let locations: [ProtectedLocation]
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Some locations won't be measured", systemImage: "lock.circle")
                .font(.headline)

            Text("macOS withholds these from apps until you allow it. Everything else will still be measured, and the total will say what was left out.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(locations) { location in
                Label(location.name, systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Privacy Settings…", action: onOpenSettings)
                Button("Scan Anyway", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

/// Offers the rescan that newly granted access makes worthwhile (FR-019).
struct AccessGrantedBanner: View {
    let onRescan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text("Full Disk Access is on. A new scan would find more than the last one.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Rescan", action: onRescan)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
