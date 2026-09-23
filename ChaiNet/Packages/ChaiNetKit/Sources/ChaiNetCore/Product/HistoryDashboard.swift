import Foundation

public enum HistoryRange: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case today, days7, days30, all
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .today: "今天"
        case .days7: "7 天"
        case .days30: "30 天"
        case .all: "全部"
        }
    }

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .days7: calendar.date(byAdding: .day, value: -7, to: now)
        case .days30: calendar.date(byAdding: .day, value: -30, to: now)
        case .all: nil
        }
    }
}

public struct TrendPoint: Codable, Sendable, Hashable, Identifiable {
    public var date: Date
    public var value: Double
    public var network: NetworkClass
    public var id: String { "\(date.timeIntervalSince1970)-\(network.rawValue)" }
}

public struct MetricTrend: Codable, Sendable, Hashable, Identifiable {
    public var metric: BaselineMetric
    public var points: [TrendPoint]
    public var median: Double?
    public var p10: Double?
    public var p90: Double?
    public var id: BaselineMetric { metric }
}

/// Aggregations for the History Dashboard.
public enum HistoryAggregator {
    public static func filter(_ results: [TestResult], range: HistoryRange, network: NetworkClass? = nil,
                              now: Date = Date(), calendar: Calendar = .current) -> [TestResult] {
        let start = range.startDate(now: now, calendar: calendar)
        return results.filter { r in
            (start.map { r.date >= $0 } ?? true) && (network.map { NetworkClass(snapshot: r.network) == $0 } ?? true)
        }
    }

    public static func trends(_ results: [TestResult]) -> [MetricTrend] {
        BaselineMetric.allCases.map { metric in
            let points = results.compactMap { r -> TrendPoint? in
                guard let v = metric.value(in: r.metrics) else { return nil }
                return TrendPoint(date: r.date, value: v, network: NetworkClass(snapshot: r.network))
            }.sorted { $0.date < $1.date }
            let values = points.map(\.value)
            return MetricTrend(metric: metric, points: points, median: Descriptive.median(values),
                               p10: Percentile.value(0.1, in: values), p90: Percentile.value(0.9, in: values))
        }
    }

    /// Per-network medians — powers the "5G vs LTE vs Wi-Fi" compare view.
    public static func medianByNetwork(_ results: [TestResult], metric: BaselineMetric) -> [NetworkClass: Double] {
        var groups: [NetworkClass: [Double]] = [:]
        for r in results {
            guard let v = metric.value(in: r.metrics) else { continue }
            groups[NetworkClass(snapshot: r.network), default: []].append(v)
        }
        return groups.compactMapValues { Descriptive.median($0) }
    }
}
