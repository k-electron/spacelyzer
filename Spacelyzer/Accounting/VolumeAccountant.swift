import Foundation

/// Reconciles what a scan measured against what the volume says it is using, and names every
/// reason the two differ (FR-014 through FR-017).
///
/// Runs synchronously and off the main actor by contract: it shells out to `diskutil` twice, and
/// Principle III does not allow the interface to wait on that.
nonisolated struct VolumeAccountant: Sendable {
    let snapshotReader: SnapshotReader
    let containerReader: ContainerReader

    init(
        snapshotReader: SnapshotReader = SnapshotReader(),
        containerReader: ContainerReader = ContainerReader()
    ) {
        self.snapshotReader = snapshotReader
        self.containerReader = containerReader
    }

    func account(
        scanRoot: URL,
        measuredBytes: Int64,
        skipped: [(path: String, reason: SkipReason)] = []
    ) -> VolumeAccounting? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeURLKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? scanRoot.resourceValues(forKeys: keys),
              let totalCapacity = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity
        else { return nil }

        let volumeURL = values.volume ?? scanRoot
        let coversWholeVolume =
            volumeURL.standardizedFileURL == scanRoot.standardizedFileURL

        // Available capacity already includes what the system would purge if pressed, so the
        // difference is the purgeable figure. It is not added to the causes below: it lives inside
        // used space and consists largely of caches the scan already counted as files.
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        let purgeable = max(0, important - Int64(available))

        var causes: [UnaccountedEntry] = []
        causes.append(contentsOf: inaccessibleLocations(from: skipped))
        if coversWholeVolume {
            causes.append(contentsOf: otherVolumes(holding: scanRoot))
            causes.append(contentsOf: snapshots(on: volumeURL))
        }

        var accounting = VolumeAccounting(
            volumeName: values.volumeName ?? volumeURL.lastPathComponent,
            totalCapacity: Int64(totalCapacity),
            availableBytes: Int64(available),
            purgeableBytes: purgeable,
            measuredBytes: measuredBytes,
            identifiedCauses: causes
        )

        // Measuring one folder leaves the rest of the volume unmeasured, which is not a defect to
        // be itemized but the ordinary consequence of the choice. Naming it keeps the arithmetic
        // exact and stops the remainder from presenting an expected gap as a mystery.
        if !coversWholeVolume, accounting.unattributedBytes > 0 {
            causes.append(
                UnaccountedEntry(cause: .outsideScanRoot, bytes: accounting.unattributedBytes)
            )
            accounting = VolumeAccounting(
                volumeName: accounting.volumeName,
                totalCapacity: accounting.totalCapacity,
                availableBytes: accounting.availableBytes,
                purgeableBytes: accounting.purgeableBytes,
                measuredBytes: accounting.measuredBytes,
                identifiedCauses: causes
            )
        }

        return accounting
    }

    /// Locations the scan could not read. Their sizes are unknowable precisely because they could
    /// not be read, so they are named without one and their bytes fall to the remainder (FR-017).
    private func inaccessibleLocations(
        from skipped: [(path: String, reason: SkipReason)]
    ) -> [UnaccountedEntry] {
        // Locations skipped for sitting on another volume are deliberately absent: their bytes
        // belong to that volume's accounting, not this one's.
        let denied = skipped
            .filter { $0.reason == .permissionDenied || $0.reason == .unreadable }
            .map(\.path)
        let excluded = skipped.filter { $0.reason == .userExcluded }.map(\.path)

        var entries: [UnaccountedEntry] = []
        if !denied.isEmpty {
            entries.append(
                UnaccountedEntry(
                    cause: .permissionDenied,
                    bytes: nil,
                    locations: denied,
                    sizeUnknownReason: denied.count == 1
                        ? "One location could not be opened, so its contents could not be measured."
                        : "\(denied.count) locations could not be opened, so their contents could not be measured."
                )
            )
        }
        if !excluded.isEmpty {
            entries.append(
                UnaccountedEntry(
                    cause: .userExcluded,
                    bytes: nil,
                    locations: excluded,
                    sizeUnknownReason: "Excluded folders are skipped rather than measured, so their size is not known."
                )
            )
        }
        return entries
    }

    private func otherVolumes(holding scanRoot: URL) -> [UnaccountedEntry] {
        guard let device = ContainerReader.deviceIdentifier(forVolumeAt: scanRoot),
              let layout = containerReader.layout(containing: device)
        else { return [] }

        let unreachable = layout.volumesUnreachable(fromScanOf: device)
        guard !unreachable.isEmpty else { return [] }

        let bytes = unreachable.reduce(Int64(0)) { $0 + $1.bytesInUse }
        guard bytes > 0 else { return [] }

        return [
            UnaccountedEntry(
                cause: .otherVolumes,
                bytes: bytes,
                locations: unreachable.map(\.name)
            )
        ]
    }

    private func snapshots(on volumeURL: URL) -> [UnaccountedEntry] {
        let reading = snapshotReader.snapshots(onVolumeAt: volumeURL)
        guard !reading.snapshots.isEmpty || reading.totalBytes == nil else { return [] }

        return [
            UnaccountedEntry(
                cause: .snapshots,
                bytes: reading.totalBytes,
                locations: reading.snapshots.map(\.name),
                sizeUnknownReason: reading.sizeUnknownReason
            )
        ]
    }
}
