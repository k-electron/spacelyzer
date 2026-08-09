import Foundation

nonisolated struct VolumeSnapshot: Sendable, Equatable {
    let name: String
    let uuid: String
    let isPurgeable: Bool
}

/// What could be learned about snapshots, including the case where the answer is "not much".
nonisolated struct SnapshotReading: Sendable, Equatable {
    let snapshots: [VolumeSnapshot]
    /// Bytes held by these snapshots, or nil when that cannot be determined. Zero and nil mean
    /// different things: zero is a measurement, nil is an admission.
    let totalBytes: Int64?
    /// Always set when `totalBytes` is nil, so the gap is never presented bare (FR-017).
    let sizeUnknownReason: String?

    static let none = SnapshotReading(snapshots: [], totalBytes: 0, sizeUnknownReason: nil)

    static func undeterminable(_ reason: String, snapshots: [VolumeSnapshot] = []) -> Self {
        SnapshotReading(snapshots: snapshots, totalBytes: nil, sizeUnknownReason: reason)
    }
}

/// Snapshot enumeration, via the one interface allowed to run `diskutil`.
///
/// This never throws. A snapshot reading that fails still has to produce something the accounting
/// can show, because FR-017 forbids reporting undeterminable space as zero or dropping it. Failure
/// is therefore a value: the snapshots this reader could not size are named, and their bytes fall
/// through to the unattributed remainder carrying the reason with them.
nonisolated struct SnapshotReader: Sendable {
    let diskUtility: any DiskUtilityRunning

    init(diskUtility: any DiskUtilityRunning = DiskUtility()) {
        self.diskUtility = diskUtility
    }

    func snapshots(onVolumeAt url: URL) -> SnapshotReading {
        let output: [String: Any]
        do {
            output = try diskUtility.plist(["apfs", "listSnapshots", "-plist", url.path])
        } catch DiskUtilityError.unreadableOutput {
            return .undeterminable(
                "macOS listed its snapshots in a form this version of Spacelyzer cannot read."
            )
        } catch {
            // A non-APFS volume is the ordinary case here, not a fault: it cannot hold snapshots,
            // so nothing is missing from the accounting.
            return isAPFS(url) == false
                ? .none
                : .undeterminable("macOS did not answer when asked to list its snapshots.")
        }

        guard let raw = output["Snapshots"] as? [[String: Any]] else {
            return .undeterminable(
                "macOS listed its snapshots in a form this version of Spacelyzer cannot read."
            )
        }

        let snapshots = raw.compactMap(Self.snapshot(from:))
        guard !snapshots.isEmpty else { return .none }

        // Enumerating snapshots and sizing them are different capabilities, and macOS only offers
        // the first. The plist carries names, UUIDs, and transaction ids, but no size field of any
        // kind, so there is nothing here to parse a number out of. Research R4 records the output.
        return .undeterminable(
            snapshots.count == 1
                ? "macOS reports that a snapshot exists but does not report how much space it holds."
                : "macOS reports that \(snapshots.count) snapshots exist but does not report how much space they hold.",
            snapshots: snapshots
        )
    }

    private static func snapshot(from entry: [String: Any]) -> VolumeSnapshot? {
        guard let uuid = entry["SnapshotUUID"] as? String else { return nil }
        return VolumeSnapshot(
            name: entry["SnapshotName"] as? String ?? uuid,
            uuid: uuid,
            isPurgeable: entry["Purgeable"] as? Bool ?? false
        )
    }

    private func isAPFS(_ url: URL) -> Bool {
        let type = try? url.resourceValues(forKeys: [.volumeTypeNameKey]).volumeTypeName
        return type?.localizedCaseInsensitiveContains("apfs") ?? false
    }
}
