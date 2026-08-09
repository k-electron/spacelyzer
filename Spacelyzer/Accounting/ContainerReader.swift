import Foundation

nonisolated struct ContainerVolume: Sendable, Equatable {
    let deviceIdentifier: String
    let name: String
    let bytesInUse: Int64
    let roles: [String]

    var role: String? { roles.first }
}

nonisolated struct ContainerLayout: Sendable, Equatable {
    let reference: String
    let volumes: [ContainerVolume]

    func volume(withDevice device: String) -> ContainerVolume? {
        volumes.first { $0.deviceIdentifier == device }
    }

    /// Volumes a scan of `device` can never reach as files.
    ///
    /// A macOS install is split across a read-only System volume and a writable Data volume that
    /// firmlinks stitch into one tree, so scanning either one covers both. Everything else in the
    /// container — recovery, preboot, virtual memory, other installs — holds real space that no
    /// amount of walking the filesystem will find.
    func volumesUnreachable(fromScanOf device: String) -> [ContainerVolume] {
        let reachable = Set(reachableDevices(from: device))
        return volumes.filter { !reachable.contains($0.deviceIdentifier) }
    }

    private func reachableDevices(from device: String) -> [String] {
        guard let scanned = volume(withDevice: device) else { return [device] }
        guard let partnerRole = Self.firmlinkPartner(of: scanned.role) else {
            return [scanned.deviceIdentifier]
        }

        // Only when the pairing is unambiguous. A container holding two macOS installs has two
        // Data volumes and no way here to tell which belongs to this one, so the extras are
        // reported as unreachable. That overstates the cause rather than understating it, and an
        // overstatement surfaces as an overlap the accounting flags rather than a wrong total it
        // presents with confidence.
        let candidates = volumes.filter { $0.role == partnerRole }
        guard candidates.count == 1 else { return [scanned.deviceIdentifier] }
        return [scanned.deviceIdentifier, candidates[0].deviceIdentifier]
    }

    private static func firmlinkPartner(of role: String?) -> String? {
        switch role {
        case "System": "Data"
        case "Data": "System"
        default: nil
        }
    }
}

/// Reads the APFS container layout, via the one interface allowed to run `diskutil`.
///
/// This exists because a startup disk is not one volume but several sharing a pool of space, and
/// only two of them can be walked as files. On a stock Mac the rest hold about 25 GB, which is
/// enough to blow past the one percent reconciliation SC-007 asks for if it is left unnamed.
nonisolated struct ContainerReader: Sendable {
    let diskUtility: any DiskUtilityRunning

    init(diskUtility: any DiskUtilityRunning = DiskUtility()) {
        self.diskUtility = diskUtility
    }

    func layout(containing device: String) -> ContainerLayout? {
        guard let output = try? diskUtility.plist(["apfs", "list", "-plist"]),
              let containers = output["Containers"] as? [[String: Any]]
        else { return nil }

        for container in containers {
            guard let reference = container["ContainerReference"] as? String,
                  let rawVolumes = container["Volumes"] as? [[String: Any]]
            else { continue }

            let volumes = rawVolumes.compactMap(Self.volume(from:))
            guard volumes.contains(where: { $0.deviceIdentifier == device }) else { continue }
            return ContainerLayout(reference: reference, volumes: volumes)
        }
        return nil
    }

    private static func volume(from entry: [String: Any]) -> ContainerVolume? {
        guard let device = entry["DeviceIdentifier"] as? String else { return nil }
        return ContainerVolume(
            deviceIdentifier: device,
            name: entry["Name"] as? String ?? device,
            bytesInUse: (entry["CapacityInUse"] as? NSNumber)?.int64Value ?? 0,
            roles: entry["Roles"] as? [String] ?? []
        )
    }

    /// The BSD device backing a mounted path, as `diskutil` spells it.
    static func deviceIdentifier(forVolumeAt url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }

        let mountedFrom = withUnsafeBytes(of: info.f_mntfromname) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
        guard let device = mountedFrom?.replacingOccurrences(of: "/dev/", with: ""),
              device.hasPrefix("disk")
        else { return nil }

        return stripSnapshotSuffix(device)
    }

    /// The sealed system volume is mounted from its own snapshot, so `/` reports `disk3s1s1` while
    /// the container lists the volume as `disk3s1`. Matching one against the other without this
    /// finds nothing.
    static func stripSnapshotSuffix(_ device: String) -> String {
        guard device.hasPrefix("disk") else { return device }
        let parts = device.dropFirst("disk".count).split(separator: "s")
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return device }
        return "disk" + parts.dropLast().joined(separator: "s")
    }
}
