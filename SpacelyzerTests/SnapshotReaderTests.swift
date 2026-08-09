import Foundation
import Testing
@testable import Spacelyzer

private struct StubDiskUtility: DiskUtilityRunning {
    let handler: @Sendable ([String]) throws -> Data

    init(failing error: DiskUtilityError) {
        handler = { _ in throw error }
    }

    init(returning xml: String) {
        let data = Data(xml.utf8)
        handler = { _ in data }
    }

    func run(_ arguments: [String]) throws -> Data { try handler(arguments) }
}

/// Captured verbatim from `diskutil apfs listSnapshots -plist /`, so the parser is tested against
/// what the tool actually emits rather than what it was assumed to emit.
private let realOutput = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Snapshots</key>
    <array>
        <dict>
            <key>LimitingContainerShrink</key><true/>
            <key>Purgeable</key><false/>
            <key>RevertTo</key><false/>
            <key>RootTo</key><false/>
            <key>SnapshotName</key><string>com.apple.os.update-5B92CE4BA1034457</string>
            <key>SnapshotUUID</key><string>A8D7E960-D5DE-46FB-B435-F8B94D6F82C5</string>
            <key>SnapshotXID</key><integer>4983886</integer>
        </dict>
    </array>
</dict>
</plist>
"""

private let emptyOutput = """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Snapshots</key><array/></dict></plist>
"""

@Suite("Snapshot reading")
struct SnapshotReaderTests {
    private let anyVolume = URL(fileURLWithPath: "/")

    @Test("A snapshot that exists is named even though macOS reports no size for it")
    func snapshotsAreNamedButNotSized() throws {
        let reader = SnapshotReader(diskUtility: StubDiskUtility(returning: realOutput))

        let reading = reader.snapshots(onVolumeAt: anyVolume)

        #expect(reading.snapshots.count == 1)
        #expect(reading.snapshots.first?.uuid == "A8D7E960-D5DE-46FB-B435-F8B94D6F82C5")
        #expect(reading.snapshots.first?.isPurgeable == false)

        // The plist carries names, UUIDs, and transaction ids, and no size field of any kind.
        // FR-017 forbids calling that zero, so it is nil with the reason attached.
        #expect(reading.totalBytes == nil)
        let reason = try #require(reading.sizeUnknownReason)
        #expect(reason.contains("does not report how much space"))
    }

    @Test("No snapshots means zero bytes, which is a measurement rather than an admission")
    func absenceIsKnowable() {
        let reader = SnapshotReader(diskUtility: StubDiskUtility(returning: emptyOutput))

        let reading = reader.snapshots(onVolumeAt: anyVolume)

        #expect(reading.snapshots.isEmpty)
        #expect(reading.totalBytes == 0)
        #expect(reading.sizeUnknownReason == nil)
    }

    @Test("Output the parser cannot read falls through to the residual with its reason stated")
    func unparsableOutputDegrades() throws {
        let reader = SnapshotReader(
            diskUtility: StubDiskUtility(returning: "not a plist at all")
        )

        let reading = reader.snapshots(onVolumeAt: anyVolume)

        #expect(reading.totalBytes == nil)
        let reason = try #require(reading.sizeUnknownReason)
        #expect(reason.contains("cannot read"))
    }

    @Test("A plist in an unexpected shape is treated as unreadable rather than as empty")
    func unexpectedShapeIsNotMistakenForAbsence() throws {
        // The failure that matters most: a future release renames the key and the app silently
        // reports zero snapshots on a disk full of them.
        let renamed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>SnapshotList</key><array/></dict></plist>
        """
        let reader = SnapshotReader(diskUtility: StubDiskUtility(returning: renamed))

        let reading = reader.snapshots(onVolumeAt: anyVolume)

        #expect(reading.totalBytes == nil)
        #expect(try #require(reading.sizeUnknownReason).contains("cannot read"))
    }

    @Test("A tool that will not run degrades with a reason instead of throwing")
    func unavailableToolDegrades() throws {
        let reader = SnapshotReader(diskUtility: StubDiskUtility(failing: .toolUnavailable))

        let reading = reader.snapshots(onVolumeAt: anyVolume)

        #expect(reading.totalBytes == nil)
        let reason = try #require(reading.sizeUnknownReason)
        #expect(reason.contains("did not answer"))
    }
}
