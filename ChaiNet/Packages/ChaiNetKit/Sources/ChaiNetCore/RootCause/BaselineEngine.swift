import Foundation

public enum BaselineMetric: String, Codable, Sendable, Hashable, CaseIterable {
    case downloadMbps, uploadMbps, latencyMs, jitterMs, lossPercent

    /// Throughput: lower is worse. Latency / jitter / loss: higher is worse.
    public var higherIsBetter: Bool { self == .downloadMbps || self == .uploadMbps }

    public var displayName: String {
        switch self {
        case .downloadMbps: "下載"
        case .uploadMbps: "上傳"
        case .latencyMs: "延遲"
        case .jitterMs: "抖動"
        case .lossPercent: "封包遺失"
        }
    }

    public var unit: String {
        switch self {
        case .downloadMbps, .uploadMbps: "Mbps"
        case .latencyMs, .jitterMs: "ms"
        case .lossPercent: "%"
        }
    }

    public func value(in m: MetricSnapshot) -> Double? {
        switch self {
        case .downloadMbps: m.downloadMbps
        case .uploadMbps: m.uploadMbps
        case .latencyMs: m.idleLatencyMs
        case .jitterMs: m.jitterMs
        case .lossPercent: m.lossPercent
        }
    }
}

public enum TimeOfDayBucket: String, Codable, Sendable, Hashable, CaseIterable {
    case night      // 00–06
    case morning    // 06–12
    case afternoon  // 12–18
    case evening    // 18–24 (typical residential peak)

    public init(date: Date, calendar: Calendar = .current) {
        switch calendar.component(.hour, from: date) {
        case 0..<6: self = .night
        case 6..<12: self = .morning
        case 12..<18: self = .afternoon
        default: self = .evening
        }
    }

    public var displayName: String {
        switch self {
        case .night: "深夜（0–6 時）"
        case .morning: "上午（6–12 時）"
        case .afternoon: "下午（12–18 時）"
        case .evening: "晚間尖峰（18–24 時）"
        }
    }
}

/// Grouping key: network type × time of day × area. `nil` components mean "any".
public struct BaselineKey: Codable, Sendable, Hashable {
    public var network: NetworkClass
    public var timeBucket: TimeOfDayBucket?
    /// Location rounded to a 0.1° grid (~11 km). Local only; never uploaded.
    public var region: String?

    public init(network: NetworkClass, timeBucket: TimeOfDayBucket?, region: String?) {
        self.network = network
        self.timeBucket = timeBucket
        self.region = region
    }

    public static func region(for point: GeoPoint?) -> String? {
        guard let p = point else { return nil }
        let lat = (p.latitude * 10).rounded(.down) / 10
        let lon = (p.longitude * 10).rounded(.down) / 10
        return "\(Fmt.d(lat, 1)),\(Fmt.d(lon, 1))"
    }

    public var displayName: String {
        var parts = [network.displayName]
        if let timeBucket { parts.append(timeBucket.displayName) }
        if region != nil { parts.append("同一區域") }
        return parts.joined(separator: " · ")
    }
}

public struct MetricBaseline: Codable, Sendable, Hashable {
    public var metric: BaselineMetric
    public var count: Int
    public var median: Double
    /// Median absolute deviation.
    public var mad: Double
    public var p10: Double
    public var p90: Double
}

public struct Baseline: Codable, Sendable, Hashable {
    public var key: BaselineKey
    public var sampleCount: Int
    public var metrics: [MetricBaseline]

    public func metric(_ m: BaselineMetric) -> MetricBaseline? { metrics.first { $0.metric == m } }
}

/// All baselines built from history, with hierarchical lookup.
public struct BaselineStore: Codable, Sendable, Hashable {
    public var baselines: [Baseline]

    public init(baselines: [Baseline]) {
        self.baselines = baselines
    }

    /// Most specific baseline available for a result:
    ///
    ///     (network, time, region) → (network, time, ·) → (network, ·, region) → (network, ·, ·)
    public func baseline(for result: TestResult, calendar: Calendar = .current) -> Baseline? {
        let network = NetworkClass(snapshot: result.network)
        let time = TimeOfDayBucket(date: result.date, calendar: calendar)
        let region = BaselineKey.region(for: result.location)
        let candidates = [
            BaselineKey(network: network, timeBucket: time, region: region),
            BaselineKey(network: network, timeBucket: time, region: nil),
            BaselineKey(network: network, timeBucket: nil, region: region),
            BaselineKey(network: network, timeBucket: nil, region: nil),
        ]
        for key in candidates {
            if let b = baselines.first(where: { $0.key == key }) { return b }
        }
        return nil
    }
}

/// Learns what is "normal" for this device from local history.
///
/// Every historical result contributes to the four keys of its lookup hierarchy. A baseline is
/// kept only when at least `minimumSamples` results exist for that key. For each metric:
///
///     median, MAD = median(|x − median|), P10, P90      (robust to outliers)
///
/// Only the most recent `maximumAgeDays` are used so the baseline follows plan / router changes.
public struct BaselineEngine: Sendable {
    public var minimumSamples: Int
    public var maximumAgeDays: Int

    public init(minimumSamples: Int = 5, maximumAgeDays: Int = 90) {
        self.minimumSamples = max(2, minimumSamples)
        self.maximumAgeDays = maximumAgeDays
    }

    public func build(from history: [TestResult], now: Date = Date(), calendar: Calendar = .current) -> BaselineStore {
        let cutoff = now.addingTimeInterval(-Double(maximumAgeDays) * 86_400)
        var buckets: [BaselineKey: [MetricSnapshot]] = [:]
        for result in history where result.date >= cutoff && !result.wasCancelled {
            let network = NetworkClass(snapshot: result.network)
            guard network != .unknown else { continue }
            let time = TimeOfDayBucket(date: result.date, calendar: calendar)
            let region = BaselineKey.region(for: result.location)
            let metrics = result.metrics
            var keys = [BaselineKey(network: network, timeBucket: time, region: nil),
                        BaselineKey(network: network, timeBucket: nil, region: nil)]
            if let region {
                keys.append(BaselineKey(network: network, timeBucket: time, region: region))
                keys.append(BaselineKey(network: network, timeBucket: nil, region: region))
            }
            for key in keys { buckets[key, default: []].append(metrics) }
        }

        var baselines: [Baseline] = []
        for (key, snapshots) in buckets where snapshots.count >= minimumSamples {
            let metrics = BaselineMetric.allCases.compactMap { metric -> MetricBaseline? in
                let values = snapshots.compactMap { metric.value(in: $0) }
                guard values.count >= minimumSamples else { return nil }
                let sorted = values.sorted()
                return MetricBaseline(metric: metric, count: values.count,
                                      median: Percentile.value(0.5, sorted: sorted)!,
                                      mad: Descriptive.medianAbsoluteDeviation(values)!,
                                      p10: Percentile.value(0.1, sorted: sorted)!,
                                      p90: Percentile.value(0.9, sorted: sorted)!)
            }
            if !metrics.isEmpty { baselines.append(Baseline(key: key, sampleCount: snapshots.count, metrics: metrics)) }
        }
        baselines.sort { $0.key.network.rawValue + ($0.key.timeBucket?.rawValue ?? "") < $1.key.network.rawValue + ($1.key.timeBucket?.rawValue ?? "") }
        return BaselineStore(baselines: baselines)
    }
}
