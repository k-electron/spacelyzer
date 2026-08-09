import AppKit
import Foundation

nonisolated struct VolumeDescriptor: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
}

nonisolated struct ProtectedLocation: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
}

/// Everything to do with what the app is permitted to read.
///
/// The app runs unsandboxed, so it can enumerate volumes and read directly. The remaining
/// constraint is the system's privacy protection over locations like Desktop and Documents, which
/// the user grants through Full Disk Access. The app never claims to require it (constitution,
/// Platform and Technology Constraints).
@MainActor
@Observable
final class AccessBroker {
    private(set) var hasFullDiskAccess: Bool
    /// Set when access appears after having been absent, so the interface can offer the rescan
    /// that would now find more (FR-019).
    private(set) var accessWasJustGranted = false

    init() {
        hasFullDiskAccess = Self.probeFullDiskAccess()
    }

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
        panel.message = "Choose a folder to analyze"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Locations the system withholds by default. Listed rather than probed: reading one without
    /// permission raises a system prompt, and an app that fires five prompts on launch to build a
    /// warning has become the problem it was describing.
    var protectedLocations: [ProtectedLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ProtectedLocation(url: home.appending(path: "Desktop"), name: "Desktop"),
            ProtectedLocation(url: home.appending(path: "Documents"), name: "Documents"),
            ProtectedLocation(url: home.appending(path: "Downloads"), name: "Downloads"),
            ProtectedLocation(url: home.appending(path: "Library/Mail"), name: "Mail"),
            ProtectedLocation(url: home.appending(path: "Library/Messages"), name: "Messages"),
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Whether a scan of this location stands to miss protected content. Scanning a folder well
    /// away from home has nothing to warn about, and warning anyway trains people to dismiss it.
    func protectedLocationsAtRisk(under root: URL) -> [ProtectedLocation] {
        guard !hasFullDiskAccess else { return [] }
        let rootPath = root.standardizedFileURL.path
        return protectedLocations.filter {
            $0.url.standardizedFileURL.path.hasPrefix(rootPath)
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-checks on returning to the app, which is when a grant made in System Settings shows up.
    func refreshAccessState() {
        let granted = Self.probeFullDiskAccess()
        if granted, !hasFullDiskAccess {
            accessWasJustGranted = true
        }
        hasFullDiskAccess = granted
    }

    func acknowledgeGrant() {
        accessWasJustGranted = false
    }

    /// Opening the privacy database is refused without Full Disk Access and permitted with it,
    /// and unlike the folders above it raises no prompt either way. Nothing is read from the file;
    /// only whether it opens is of interest.
    private static func probeFullDiskAccess() -> Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(probe, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
