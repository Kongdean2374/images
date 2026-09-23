import Foundation

public enum ExportFormat: String, Sendable, CaseIterable {
    case json
    case csv

    public var fileExtension: String { rawValue }
}

public struct ExportOptions: Sendable {
    /// Location is stripped unless the user explicitly opts in (privacy default).
    public var includeLocation: Bool
    /// Include full sample timelines in JSON.
    public var includeTimelines: Bool

    public init(includeLocation: Bool = false, includeTimelines: Bool = true) {
        self.includeLocation = includeLocation
        self.includeTimelines = includeTimelines
    }
}

/// CSV / JSON export.
public enum ResultExporter {

    public static let csvColumns = [
        "id", "date", "kind", "server", "interface", "vpn", "expensive", "constrained",
        "download_mbps", "download_peak_mbps", "download_min_mbps", "download_p95_mbps", "download_stability",
        "upload_mbps", "upload_peak_mbps", "upload_min_mbps", "upload_p95_mbps", "upload_stability",
        "ping_min_ms", "ping_avg_ms", "ping_median_ms", "ping_max_ms", "ping_p95_ms", "ping_p99_ms", "jitter_ms",
        "loss_percent", "random_loss_percent", "burst_loss_percent", "loss_pattern",
        "download_bloat_ms", "upload_bloat_ms", "bufferbloat_grade",
        "score_overall", "score_gaming", "score_streaming", "score_voice", "score_upload",
        "findings", "latitude", "longitude",
    ]

    /// JSON: ISO-8601 dates, sorted keys, pretty printed. Deterministic for diffing.
    public static func json(_ results: [TestResult], options: ExportOptions = ExportOptions()) throws -> Data {
        let prepared = results.map { prepare($0, options) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(prepared)
    }

    public static func decodeJSON(_ data: Data) throws -> [TestResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TestResult].self, from: data)
    }

    /// CSV (RFC 4180): comma separated, CRLF line endings, fields containing `,` `"` CR or LF
    /// are quoted and embedded quotes doubled. Missing values are empty fields (never 0).
    public static func csv(_ results: [TestResult], options: ExportOptions = ExportOptions()) -> String {
        var lines = [csvColumns.joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        for r in results.map({ prepare($0, options) }) {
            let dl = r.download?.summary, ul = r.upload?.summary
            let lat = (r.idleLatency ?? r.gaming?.idle ?? r.voice?.latency ?? r.monitoring?.statistics)?.rtt
            let loss = (r.packetLoss ?? r.idleLatency ?? r.gaming?.idle ?? r.voice?.latency ?? r.monitoring?.statistics)?.loss
            let fields: [String?] = [
                r.id.uuidString, iso.string(from: r.date), r.kind.rawValue, r.server?.name,
                r.network.primaryInterface.rawValue, r.network.vpn.state.rawValue,
                String(r.network.isExpensive), String(r.network.isConstrained),
                num(dl?.averageMbps), num(dl?.peakMbps), num(dl?.minimumMbps), num(dl?.p95Mbps), num(dl?.stability.score),
                num(ul?.averageMbps), num(ul?.peakMbps), num(ul?.minimumMbps), num(ul?.p95Mbps), num(ul?.stability.score),
                num(lat?.minimum), num(lat?.average), num(lat?.median), num(lat?.maximum), num(lat?.p95), num(lat?.p99), num(lat?.jitter),
                num(loss?.lossPercent), num(loss?.randomLossPercent), num(loss?.burstLossPercent), loss?.pattern.rawValue,
                num(r.bufferbloat?.downloadIncreaseMs), num(r.bufferbloat?.uploadIncreaseMs), r.bufferbloat?.grade.rawValue,
                r.scores.overall.map(String.init), r.scores.gaming.map(String.init), r.scores.streaming.map(String.init),
                r.scores.voice.map(String.init), r.scores.upload.map(String.init),
                r.findings.map(\.code.rawValue).joined(separator: ";"),
                num(r.location?.latitude, 5), num(r.location?.longitude, 5),
            ]
            lines.append(fields.map { escape($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 field escaping.
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func num(_ v: Double?, _ digits: Int = 3) -> String? {
        guard let v, v.isFinite else { return nil }
        return String(format: "%.\(digits)f", v)
    }

    static func prepare(_ result: TestResult, _ options: ExportOptions) -> TestResult {
        var r = result
        if !options.includeLocation { r.location = nil }
        if !options.includeTimelines {
            r.download?.samples = []
            r.upload?.samples = []
            r.idleSamples = nil
            r.monitoring?.samples = []
        }
        return r
    }

    /// Plain-text summary for the share sheet.
    public static func shareSummary(_ r: TestResult) -> String {
        var parts = ["ChaiNet · \(r.kind.displayName)"]
        if let d = r.download?.summary { parts.append("下載 \(String(format: "%.1f", d.averageMbps)) Mbps（峰值 \(String(format: "%.1f", d.peakMbps))）") }
        if let u = r.upload?.summary { parts.append("上傳 \(String(format: "%.1f", u.averageMbps)) Mbps") }
        if let l = r.idleLatency?.rtt { parts.append("延遲 \(String(format: "%.0f", l.median)) ms · 抖動 \(String(format: "%.1f", l.jitter)) ms") }
        if let loss = (r.packetLoss ?? r.idleLatency)?.loss, loss.sent > 0 { parts.append("封包遺失 \(String(format: "%.2f", loss.lossPercent))%") }
        if let g = r.bufferbloat?.grade { parts.append("Bufferbloat \(g.rawValue)") }
        if let o = r.scores.overall { parts.append("綜合分數 \(o)/100") }
        parts.append(r.network.primaryInterface.displayName)
        return parts.joined(separator: "\n")
    }
}
