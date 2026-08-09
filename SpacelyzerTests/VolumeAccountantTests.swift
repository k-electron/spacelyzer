import Foundation
import Testing
@testable import Spacelyzer

/// Figures captured from a stock Apple silicon Mac, so the reconciliation is exercised against a
/// real disk layout rather than round numbers that flatter it.
private enum RealMac {
    static let totalCapacity: Int64 = 994_662_584_320
    static let available: Int64 = 573_716_692_992
    static let used: Int64 = totalCapacity - available

    /// The two volumes a scan of `/` can walk: the sealed system volume and the Data volume that
    /// firmlinks stitch into it.
    static let measured: Int64 = 12_563_816_448 + 383_116_660_736

    /// Preboot, Recovery, Update, VM, and one unrelated volume, all sharing the container.
    static let otherVolumes: Int64 = 8_987_439_104 + 1_304_141_824 + 8_179_712 + 20_480 + 14_758_940_672
}

@Suite("Volume accounting")
struct VolumeAccountantTests {

    private func accounting(
        measured: Int64 = RealMac.measured,
        causes: [UnaccountedEntry]
    ) -> VolumeAccounting {
        VolumeAccounting(
            volumeName: "Macintosh HD",
            totalCapacity: RealMac.totalCapacity,
            availableBytes: RealMac.available,
            purgeableBytes: 8_910_000_000,
            measuredBytes: measured,
            identifiedCauses: causes
        )
    }

    @Test("Measured plus every itemized cause reconciles with the volume within one percent")
    func reconcilesWithinOnePercent() {
        let result = accounting(causes: [
            UnaccountedEntry(cause: .otherVolumes, bytes: RealMac.otherVolumes)
        ])

        #expect(result.usedBytes == RealMac.used)
        #expect(result.unattributedShare < 0.01)

        // Nothing is lost in the arithmetic: the causes and the remainder close the gap exactly.
        let itemized = result.itemization.compactMap(\.bytes).reduce(0, +)
        #expect(result.measuredBytes + itemized == result.usedBytes)
    }

    @Test("Without naming the container's other volumes the reconciliation misses its target")
    func siblingVolumesAreLoadBearing() {
        // This is why `otherVolumes` exists. A stock Mac keeps around 25 GB in volumes no scan can
        // walk, which is six times the budget SC-007 allows for the unexplained remainder.
        let result = accounting(causes: [])

        #expect(result.unattributedBytes == RealMac.otherVolumes + 206_692_352)
        #expect(result.unattributedShare > 0.05)
    }

    @Test("The remainder is always present and sized, even when nothing else is known")
    func remainderIsNeverOmitted() throws {
        let result = accounting(causes: [])

        // SC-008: a gap is never shown without a stated cause. The remainder is derived rather
        // than stored, so there is no code path that can leave it out.
        let remainder = try #require(result.itemization.last)
        #expect(remainder.cause == .unattributed)
        #expect(remainder.bytes == result.unaccountedBytes)
    }

    @Test("A cause with no size hands its bytes and its reason to the remainder")
    func unsizedCauseFallsThroughWithItsReason() throws {
        let result = accounting(causes: [
            UnaccountedEntry(cause: .otherVolumes, bytes: RealMac.otherVolumes),
            UnaccountedEntry(
                cause: .snapshots,
                bytes: nil,
                locations: ["com.apple.os.update-5B92CE"],
                sizeUnknownReason: "macOS does not report how much space it holds."
            ),
        ])

        // FR-017: not reported as zero, not quietly dropped, and the reason travels with it.
        let snapshots = try #require(result.itemization.first { $0.cause == .snapshots })
        #expect(snapshots.bytes == nil)
        #expect(result.attributedBytes == RealMac.otherVolumes)

        let remainder = try #require(result.itemization.last)
        #expect(try #require(remainder.sizeUnknownReason).contains("does not report"))
    }

    @Test("Causes claiming more than the gap are flagged rather than clamped")
    func overlappingCausesAreSurfaced() {
        // Adding purgeable space as though it were a separate cause does exactly this: it double
        // counts caches the scan already measured. Research R4 records the measurement.
        let result = accounting(causes: [
            UnaccountedEntry(cause: .otherVolumes, bytes: RealMac.otherVolumes),
            UnaccountedEntry(cause: .snapshots, bytes: 8_910_000_000),
        ])

        #expect(result.causesOverlap)
        #expect(result.unattributedBytes < 0)
        #expect(result.itemization.last?.sizeUnknownReason?.contains("overlap") == true)
    }

    @Test("An empty volume reconciles without dividing by zero")
    func emptyVolumeIsSafe() {
        let result = VolumeAccounting(
            volumeName: "Empty",
            totalCapacity: 0,
            availableBytes: 0,
            purgeableBytes: 0,
            measuredBytes: 0,
            identifiedCauses: []
        )

        #expect(result.unattributedShare == 0)
        #expect(result.itemization.count == 1)
    }
}

@Suite("APFS container layout")
struct ContainerLayoutTests {

    private let layout = ContainerLayout(
        reference: "disk3",
        volumes: [
            ContainerVolume(deviceIdentifier: "disk3s1", name: "Macintosh HD", bytesInUse: 12_563_816_448, roles: ["System"]),
            ContainerVolume(deviceIdentifier: "disk3s2", name: "Preboot", bytesInUse: 8_987_439_104, roles: ["Preboot"]),
            ContainerVolume(deviceIdentifier: "disk3s5", name: "Data", bytesInUse: 383_116_660_736, roles: ["Data"]),
            ContainerVolume(deviceIdentifier: "disk3s7", name: "Nix Store", bytesInUse: 14_758_940_672, roles: []),
        ]
    )

    @Test("Scanning the system volume also covers the Data volume firmlinked into it")
    func firmlinkPartnerIsReachable() {
        let unreachable = layout.volumesUnreachable(fromScanOf: "disk3s1").map(\.name)

        #expect(unreachable == ["Preboot", "Nix Store"])
    }

    @Test("Scanning the Data volume also covers its system partner")
    func pairingWorksInBothDirections() {
        let unreachable = layout.volumesUnreachable(fromScanOf: "disk3s5").map(\.name)

        #expect(unreachable == ["Preboot", "Nix Store"])
    }

    @Test("An ambiguous pairing overstates rather than guesses")
    func twoDataVolumesDefeatPairing() {
        // Two macOS installs share a container and there is nothing here to say which Data volume
        // belongs to which System volume. Overstating the cause surfaces as an overlap the
        // accounting flags; guessing would produce a wrong total presented with confidence.
        let ambiguous = ContainerLayout(
            reference: "disk3",
            volumes: layout.volumes + [
                ContainerVolume(deviceIdentifier: "disk3s9", name: "Data 2", bytesInUse: 1_000, roles: ["Data"])
            ]
        )

        let unreachable = ambiguous.volumesUnreachable(fromScanOf: "disk3s1").map(\.name)

        #expect(unreachable.contains("Data"))
        #expect(unreachable.contains("Data 2"))
    }

    @Test("A volume with no role has no partner and stands alone")
    func unrolledVolumeHasNoPartner() {
        let unreachable = layout.volumesUnreachable(fromScanOf: "disk3s7").map(\.name)

        #expect(unreachable == ["Macintosh HD", "Preboot", "Data"])
    }

    @Test("The sealed system volume's snapshot device resolves to the volume itself")
    func snapshotDeviceIsStripped() {
        // `/` is mounted from a snapshot, so statfs reports disk3s1s1 while the container lists
        // disk3s1. Matching one against the other without this finds no container at all.
        #expect(ContainerReader.stripSnapshotSuffix("disk3s1s1") == "disk3s1")
        #expect(ContainerReader.stripSnapshotSuffix("disk3s5") == "disk3s5")
        #expect(ContainerReader.stripSnapshotSuffix("disk10s2s1") == "disk10s2")
        #expect(ContainerReader.stripSnapshotSuffix("disk3") == "disk3")
    }
}
