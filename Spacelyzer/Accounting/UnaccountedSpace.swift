import Foundation

/// A named reason the volume reports more space in use than the scan could measure.
nonisolated enum UnaccountedCause: Int, Codable, Sendable, CaseIterable {
    case outsideScanRoot
    case permissionDenied
    case userExcluded
    case otherVolumes
    case snapshots
    case unattributed

    var label: String {
        switch self {
        case .outsideScanRoot: "The rest of this volume"
        case .permissionDenied: "Locations you haven't granted access to"
        case .userExcluded: "Folders you excluded"
        case .otherVolumes: "Other volumes on the same drive"
        case .snapshots: "System snapshots"
        case .unattributed: "Unaccounted for"
        }
    }

    /// Plain language, because a number without a reason is what sent the user looking in the
    /// first place (FR-017).
    var explanation: String {
        switch self {
        case .outsideScanRoot:
            """
            You analyzed one folder rather than the whole volume. Everything else stored on it is \
            still using space, and is grouped here rather than broken down.
            """
        case .permissionDenied:
            """
            macOS protects some folders until you allow an app to read them. Their contents are \
            not included in the analysis.
            """
        case .userExcluded:
            "You asked for these to be left out, so their contents were not analyzed."
        case .otherVolumes:
            """
            This drive is divided into several volumes that share its space. Only the one you \
            scanned can be read as files; the rest hold things like the recovery system and \
            virtual memory.
            """
        case .snapshots:
            """
            macOS keeps point-in-time copies of the disk so it can undo a failed update or restore \
            a file. They occupy real space but do not appear as files you can browse.
            """
        case .unattributed:
            """
            Space the volume reports as in use that no other cause here explains. It is shown \
            rather than hidden so the totals stay honest.
            """
        }
    }
}

/// One itemized cause, with the size when it can be known and the reason when it cannot.
nonisolated struct UnaccountedEntry: Identifiable, Sendable, Equatable {
    var id: UnaccountedCause { cause }
    let cause: UnaccountedCause
    /// Nil when the cause is real but its size cannot be determined. Those bytes fall through to
    /// the remainder rather than being reported as zero (FR-017).
    let bytes: Int64?
    let locations: [String]
    /// Stated whenever `bytes` is nil, so an unknown size is never silently blank (FR-017).
    let sizeUnknownReason: String?

    init(
        cause: UnaccountedCause,
        bytes: Int64?,
        locations: [String] = [],
        sizeUnknownReason: String? = nil
    ) {
        self.cause = cause
        self.bytes = bytes
        self.locations = locations
        self.sizeUnknownReason = sizeUnknownReason
    }
}

/// What the volume says about itself, what the scan measured, and every reason the two differ.
nonisolated struct VolumeAccounting: Sendable, Equatable {
    let volumeName: String
    let totalCapacity: Int64
    let availableBytes: Int64
    /// Space the system can reclaim on demand. It sits inside `usedBytes` and consists largely of
    /// caches the scan already counted as ordinary files, so it annotates the used figure instead
    /// of explaining the gap. Treating it as an additive cause overshoots the volume's own used
    /// figure and drives the remainder negative; research R4 records the measurement.
    let purgeableBytes: Int64
    let measuredBytes: Int64
    /// Identified causes only. The remainder is derived from these rather than stored alongside
    /// them, which is what makes it impossible to omit.
    let identifiedCauses: [UnaccountedEntry]

    var usedBytes: Int64 { totalCapacity - availableBytes }

    var unaccountedBytes: Int64 { usedBytes - measuredBytes }

    var attributedBytes: Int64 {
        identifiedCauses.compactMap(\.bytes).reduce(0, +)
    }

    /// Whatever the identified causes fail to explain. Derived, so it is always present and always
    /// correct — a gap cannot be shown without a cause because this one is computed, not remembered
    /// (SC-008).
    var unattributedBytes: Int64 { unaccountedBytes - attributedBytes }

    /// The share of the volume no cause explains. SC-007 asks this to stay within one percent.
    var unattributedShare: Double {
        guard usedBytes > 0 else { return 0 }
        return abs(Double(unattributedBytes)) / Double(usedBytes)
    }

    /// A remainder below zero means the causes claim more than the gap allows — they overlap each
    /// other or count bytes the scan already measured. Surfaced rather than clamped, because it is
    /// evidence of a real accounting error.
    var causesOverlap: Bool { unattributedBytes < 0 }

    var hasUnsizableSnapshots: Bool {
        identifiedCauses.contains { $0.cause == .snapshots && $0.bytes == nil }
    }

    /// The most of the remainder the system could reclaim, which is the closest public API gets to
    /// sizing snapshots.
    ///
    /// Local snapshots are purgeable, and so are caches the scan already counted as files. Nothing
    /// public separates the two, so this is offered as a ceiling rather than a measurement: it
    /// says how much of the remainder *could* be snapshots without claiming how much is.
    var reclaimableBoundOnRemainder: Int64? {
        guard unattributedBytes > 0, purgeableBytes > 0 else { return nil }
        return min(purgeableBytes, unattributedBytes)
    }

    /// Every cause including the remainder, which is synthesised here so it can never be left out.
    var itemization: [UnaccountedEntry] {
        identifiedCauses + [remainder]
    }

    private var remainder: UnaccountedEntry {
        UnaccountedEntry(
            cause: .unattributed,
            bytes: unattributedBytes,
            sizeUnknownReason: remainderNote
        )
    }

    /// Causes that could not be sized put their bytes here, so the remainder carries their reasons
    /// with it rather than appearing as an unexplained lump.
    private var remainderNote: String? {
        let inherited = identifiedCauses
            .filter { $0.bytes == nil }
            .compactMap(\.sizeUnknownReason)
        let overlap = causesOverlap
            ? ["The causes above account for more than the difference, so some of them overlap."]
            : []
        let notes = overlap + inherited
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
