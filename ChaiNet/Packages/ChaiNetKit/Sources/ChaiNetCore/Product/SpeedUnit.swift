import Foundation

/// Display unit for throughput.
public enum SpeedUnit: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case auto
    case kbps, mbps, gbps
    case kBps, mBps, gBps

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .auto: "Auto"
        case .kbps: "Kbps"
        case .mbps: "Mbps"
        case .gbps: "Gbps"
        case .kBps: "KB/s"
        case .mBps: "MB/s"
        case .gBps: "GB/s"
        }
    }

    public var displayName: String { self == .auto ? "自動" : symbol }

    /// Bits-based units (Kbps / Mbps / Gbps) vs byte-based (KB/s …).
    public var isBits: Bool { self == .kbps || self == .mbps || self == .gbps || self == .auto }

    /// How many of this unit one Mbps equals.
    ///
    ///     1 Mbps = 1 000 Kbps = 0.001 Gbps = 125 KB/s = 0.125 MB/s = 0.000125 GB/s
    ///
    /// SI prefixes (10³) are used for both bits and bytes, as network tools conventionally do.
    public var perMbps: Double {
        switch self {
        case .auto, .mbps: 1
        case .kbps: 1_000
        case .gbps: 0.001
        case .kBps: 125
        case .mBps: 0.125
        case .gBps: 0.000_125
        }
    }
}

public struct FormattedSpeed: Sendable, Hashable {
    public var value: String
    public var unit: SpeedUnit

    public var text: String { "\(value) \(unit.symbol)" }
}

/// Throughput formatting with primary + secondary units, e.g. "524 Mbps ≈ 65.5 MB/s".
public enum SpeedFormatter {

    /// Resolves `.auto` to a concrete bit unit: < 1 Mbps → Kbps, ≥ 1000 Mbps → Gbps, else Mbps.
    /// Byte units passed as preference keep their family (auto-scaling within bytes is not done
    /// so users who pick MB/s always see MB/s).
    public static func resolve(_ unit: SpeedUnit, mbps: Double) -> SpeedUnit {
        guard unit == .auto else { return unit }
        if mbps >= 1_000 { return .gbps }
        if mbps < 1 && mbps > 0 { return .kbps }
        return .mbps
    }

    /// Converts Mbps to the given unit.
    public static func convert(mbps: Double, to unit: SpeedUnit) -> Double {
        mbps * resolve(unit, mbps: mbps).perMbps
    }

    /// Significant-digit style rounding: ≥ 100 → 0 decimals, ≥ 10 → 1, else 2.
    public static func format(mbps: Double, unit: SpeedUnit) -> FormattedSpeed {
        let resolved = resolve(unit, mbps: mbps)
        let value = mbps * resolved.perMbps
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return FormattedSpeed(value: Fmt.d(value, digits), unit: resolved)
    }

    /// "524 Mbps ≈ 65.5 MB/s". Secondary is omitted when `nil` or identical to the primary.
    public static func dual(mbps: Double, primary: SpeedUnit, secondary: SpeedUnit?) -> String {
        let p = format(mbps: mbps, unit: primary)
        guard let secondary else { return p.text }
        let s = format(mbps: mbps, unit: secondary)
        return s.unit == p.unit ? p.text : "\(p.text) ≈ \(s.text)"
    }
}
