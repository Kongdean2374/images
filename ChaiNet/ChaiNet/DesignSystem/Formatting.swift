import Foundation
import ChaiNetCore

/// Human-readable formatting shared by all screens. Missing values render as "—" (never 0).
enum Format {
    static let dash = "—"

    static func ms(_ v: Double?, digits: Int = 0) -> String {
        guard let v, v.isFinite else { return dash }
        return String(format: "%.\(digits)f ms", v)
    }

    static func number(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return dash }
        return String(format: "%.\(digits)f", v)
    }

    static func percent(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return dash }
        return String(format: "%.\(digits)f%%", v)
    }

    static func score(_ v: Int?) -> String { v.map(String.init) ?? dash }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .decimal)
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.year().month().day().hour().minute())
    }

    static func relative(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named))
    }

    static func speed(_ mbps: Double?, settings: AppSettings, secondary: Bool = false) -> String {
        guard let mbps, mbps.isFinite else { return dash }
        return secondary
            ? SpeedFormatter.dual(mbps: mbps, primary: settings.primarySpeedUnit, secondary: settings.secondarySpeedUnit)
            : SpeedFormatter.format(mbps: mbps, unit: settings.primarySpeedUnit).text
    }

    static func speedParts(_ mbps: Double?, settings: AppSettings) -> (value: String, unit: String) {
        guard let mbps, mbps.isFinite else { return (dash, SpeedFormatter.resolve(settings.primarySpeedUnit, mbps: 1).symbol) }
        let f = SpeedFormatter.format(mbps: mbps, unit: settings.primarySpeedUnit)
        return (f.value, f.unit.symbol)
    }

    static func secondarySpeed(_ mbps: Double?, settings: AppSettings) -> String? {
        guard let mbps, mbps.isFinite, let unit = settings.secondarySpeedUnit else { return nil }
        let primary = SpeedFormatter.format(mbps: mbps, unit: settings.primarySpeedUnit)
        let s = SpeedFormatter.format(mbps: mbps, unit: unit)
        return s.unit == primary.unit ? nil : "≈ \(s.text)"
    }

    static func availability<T: Codable & Sendable & Hashable>(_ a: Availability<T>, _ f: (T) -> String) -> String {
        switch a {
        case .available(let v): f(v)
        case .unavailable: "無法取得"
        }
    }
}
