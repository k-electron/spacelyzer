import Foundation

nonisolated enum SizeUnitConvention: Int, Codable, CaseIterable, Sendable {
    /// 1 kB = 1000 bytes, matching how macOS reports sizes.
    case decimal
    /// 1 KiB = 1024 bytes.
    case binary

    var label: String {
        switch self {
        case .decimal: "Decimal (kB, MB, GB)"
        case .binary: "Binary (KiB, MiB, GiB)"
        }
    }
}

nonisolated struct SizeFormatter: Sendable {
    var convention: SizeUnitConvention

    init(convention: SizeUnitConvention = .decimal) {
        self.convention = convention
    }

    func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = convention == .decimal ? .decimal : .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// Share of a total, as a percentage string. A zero total yields no share rather than a
    /// division by zero, which happens whenever an empty folder is displayed.
    func share(of part: Int64, in total: Int64) -> String? {
        guard total > 0 else { return nil }
        let fraction = Double(part) / Double(total)
        return fraction.formatted(.percent.precision(.fractionLength(fraction < 0.01 ? 2 : 1)))
    }
}
