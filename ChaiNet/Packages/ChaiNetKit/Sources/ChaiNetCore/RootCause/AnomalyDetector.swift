import Foundation

public enum AnomalySeverity: String, Codable, Sendable, Hashable {
    case minor, major
}

/// A metric that deviates from this device's baseline.
public struct BaselineAnomaly: Codable, Sendable, Hashable, Identifiable {
    public var testID: UUID
    public var metric: BaselineMetric
    public var observed: Double
    public var baselineMedian: Double
    /// Robust z-score in the "worse" direction (positive = worse than usual).
    public var robustZ: Double
    public var severity: AnomalySeverity
    public var baselineDescription: String
    public var id: String { "\(testID.uuidString)-\(metric.rawValue)" }

    public var summary: String {
        "\(metric.displayName) \(Fmt.d(observed, 1)) \(metric.unit)，平常約 \(Fmt.d(baselineMedian, 1)) \(metric.unit)（\(baselineDescription)）"
    }
}

public enum TimelineEventKind: String, Codable, Sendable, Hashable {
    case throughputDip, latencySpike, connectionDrop, pathChange
}

/// Event inside one test's timeline (for the report timeline section).
public struct TimelineEvent: Codable, Sendable, Hashable {
    public var testID: UUID
    public var kind: TimelineEventKind
    public var offset: Double
    public var duration: Double?
    public var detail: String
}

public struct BaselineComparison: Codable, Sendable, Hashable {
    public var testID: UUID
    public var baseline: Baseline?
    public var anomalies: [BaselineAnomaly]
}

/// Detects deviation from the device's own baseline, and events inside a test's timeline.
///
/// Robust z-score, oriented so that positive = worse:
///
///     σ̂      = max(1.4826 × MAD, relativeFloor × |median|, absoluteFloor)
///     z      = (x − median) / σ̂          for latency / jitter / loss
///     z      = (median − x) / σ̂          for throughput
///     anomaly ⇔ z > 3   (major when z > 6)
///
/// The floors stop an extremely consistent history (MAD ≈ 0) from flagging trivial changes.
/// Improvements are never reported as anomalies.
public struct AnomalyDetector: Sendable {
    public var threshold: Double
    public var majorThreshold: Double

    public init(threshold: Double = 3, majorThreshold: Double = 6) {
        self.threshold = threshold
        self.majorThreshold = majorThreshold
    }

    static func floors(_ metric: BaselineMetric) -> (relative: Double, absolute: Double) {
        switch metric {
        case .downloadMbps, .uploadMbps: (0.10, 1)
        case .latencyMs: (0.15, 5)
        case .jitterMs: (0.25, 3)
        case .lossPercent: (0, 0.5)
        }
    }

    public func robustZ(value x: Double, baseline b: MetricBaseline) -> Double {
        let f = Self.floors(b.metric)
        let sigma = max(1.4826 * b.mad, f.relative * abs(b.median), f.absolute)
        return b.metric.higherIsBetter ? (b.median - x) / sigma : (x - b.median) / sigma
    }

    public func compare(_ result: TestResult, store: BaselineStore, calendar: Calendar = .current) -> BaselineComparison {
        guard let baseline = store.baseline(for: result, calendar: calendar) else {
            return BaselineComparison(testID: result.id, baseline: nil, anomalies: [])
        }
        let metrics = result.metrics
        var anomalies: [BaselineAnomaly] = []
        for mb in baseline.metrics {
            guard let x = mb.metric.value(in: metrics) else { continue }
            let z = robustZ(value: x, baseline: mb)
            if z > threshold {
                anomalies.append(BaselineAnomaly(testID: result.id, metric: mb.metric, observed: x, baselineMedian: mb.median,
                                                 robustZ: z, severity: z > majorThreshold ? .major : .minor,
                                                 baselineDescription: "\(baseline.key.displayName)，\(mb.count) 筆紀錄"))
            }
        }
        return BaselineComparison(testID: result.id, baseline: baseline, anomalies: anomalies)
    }

    /// Timeline events: throughput dips (≥ 3 consecutive samples below 50 % of the median),
    /// latency spikes, connection drops and path changes.
    public func timelineEvents(_ result: TestResult) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        for speed in [result.download, result.upload].compactMap({ $0 }) {
            let steady = speed.samples.filter { $0.offset > 1 }
            guard let median = Descriptive.median(steady.map(\.mbps)), median > 0 else { continue }
            var run: [SpeedSample] = []
            func flush() {
                if run.count >= 3, let first = run.first, let last = run.last {
                    let label = speed.direction == .download ? "下載" : "上傳"
                    let low = run.map(\.mbps).min() ?? 0
                    events.append(TimelineEvent(testID: result.id, kind: .throughputDip, offset: first.offset - first.intervalDuration,
                                                duration: last.offset - first.offset + first.intervalDuration,
                                                detail: "\(label)速度驟降至 \(Fmt.d(low, 1)) Mbps（中位數 \(Fmt.d(median, 1))）"))
                }
                run.removeAll()
            }
            for s in steady {
                if s.mbps < 0.5 * median { run.append(s) } else { flush() }
            }
            flush()
        }
        for spike in (result.monitoring?.spikes ?? []) + (result.gaming?.spikes ?? []) {
            events.append(TimelineEvent(testID: result.id, kind: .latencySpike, offset: spike.offset, duration: nil,
                                        detail: "延遲突波 \(Fmt.d(spike.rttMs, 0)) ms（基準 \(Fmt.d(spike.baselineMs, 0)) ms）"))
        }
        for drop in result.monitoring?.drops ?? [] {
            events.append(TimelineEvent(testID: result.id, kind: .connectionDrop, offset: drop.startOffset, duration: drop.duration,
                                        detail: "連線中斷，連續 \(drop.lostProbes) 個探測無回應"))
        }
        for change in result.monitoring?.pathChanges ?? [] {
            events.append(TimelineEvent(testID: result.id, kind: .pathChange, offset: change.offset, duration: nil,
                                        detail: "網路路徑變更：\(change.interface.displayName)（\(change.status.rawValue)）"))
        }
        return events.sorted { $0.offset < $1.offset }
    }
}
