import AppKit
import Foundation

nonisolated struct VolumeDescriptor: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
}

/// Everything to do with what the app is permitted to read.
///
/// The app runs unsandboxed, so it can enumerate volumes and read directly. The remaining
/// constraint is the system's privacy protection over locations like Desktop and Documents, which
/// the user grants through Full Disk Access. The app never claims to require it (constitution,
/// Platform and Technology Constraints).
@MainActor
struct AccessBroker {
    /// Volumes the user can choose to scan. A sandboxed app could not do this at all, which is
    /// one of the reasons the sandbox was dropped.
    func mountedVolumes() -> [VolumeDescriptor] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true
            else { return nil }
            return VolumeDescriptor(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(values.volumeAvailableCapacity ?? 0)
            )
        }
    }

    /// A convenience for scanning an arbitrary folder, rather than the only route to access,
    /// which is what it was under the sandbox.
    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to measure"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
