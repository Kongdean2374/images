import Foundation

/// The five scenario scores. `nil` = not enough data for that scenario.
public struct QualityScores: Codable, Sendable, Hashable {
    public var overall: Int?
    public var gaming: Int?
    public var streaming: Int?
    public var voice: Int?
    public var upload: Int?

    public init(overall: Int?, gaming: Int?, streaming: Int?, voice: Int?, upload: Int?) {
        self.overall = overall
        self.gaming = gaming
        self.streaming = streaming
        self.voice = voice
        self.upload = upload
    }

    public static let empty = QualityScores(overall: nil, gaming: nil, streaming: nil, voice: nil, upload: nil)
}

public enum ScoreMetric: String, Codable, Sendable, Hashable, CaseIterable {
    case download, upload, latency, jitter, loss, downloadBloat, uploadBloat, downloadStability, uploadStability
}

/// A hard ceiling applied after weighting — e.g. "5 % loss makes gaming bad no matter how
/// fast the link is". Weighted averages alone would let a great metric hide a fatal one.
public struct ScoreCap: Sendable, Hashable, Codable {
    public var metric: ScoreMetric
    /// Cap applies when the raw metric is ≥ this value (or ≤ when `whenBelow`).
    public var threshold: Double
    public var whenBelow: Bool
    public var maximumScore: Double

    public init(metric: ScoreMetric, threshold: Double, whenBelow: Bool = false, maximumScore: Double) {
        self.metric = metric
        self.threshold = threshold
        self.whenBelow = whenBelow
        self.maximumScore = maximumScore
    }
}

/// Weights + caps for one usage scenario.
public struct ScoreProfile: Sendable, Hashable, Codable {
    public var weights: [ScoreMetric: Double]
    public var caps: [ScoreCap]
    /// Minimum share of total weight that must be measured for a score to be produced.
    public var minimumCoverage: Double

    public init(weights: [ScoreMetric: Double], caps: [ScoreCap], minimumCoverage: Double = 0.5) {
        self.weights = weights
        self.caps = caps
        self.minimumCoverage = minimumCoverage
    }

    /// Gaming: responsiveness dominates; bandwidth barely matters.
    public static let gaming = ScoreProfile(
        weights: [.latency: 0.30, .jitter: 0.20, .loss: 0.25, .downloadBloat: 0.075, .uploadBloat: 0.075, .download: 0.05, .upload: 0.05],
        caps: [ScoreCap(metric: .loss, threshold: 2, maximumScore: 50), ScoreCap(metric: .loss, threshold: 5, maximumScore: 25),
               ScoreCap(metric: .jitter, threshold: 50, maximumScore: 40), ScoreCap(metric: .latency, threshold: 150, maximumScore: 35)])

    /// Streaming: sustained download and its stability dominate; buffers hide latency.
    public static let streaming = ScoreProfile(
        weights: [.download: 0.45, .downloadStability: 0.20, .loss: 0.10, .downloadBloat: 0.10, .jitter: 0.10, .latency: 0.05],
        caps: [ScoreCap(metric: .download, threshold: 5, whenBelow: true, maximumScore: 40),
               ScoreCap(metric: .loss, threshold: 5, maximumScore: 45)])

    /// Voice: jitter & loss (audio gaps) > latency (talk-over) > bandwidth (tiny).
    public static let voice = ScoreProfile(
        weights: [.latency: 0.25, .jitter: 0.30, .loss: 0.30, .upload: 0.05, .uploadBloat: 0.05, .downloadBloat: 0.05],
        caps: [ScoreCap(metric: .loss, threshold: 5, maximumScore: 25), ScoreCap(metric: .jitter, threshold: 80, maximumScore: 30)])

    /// Upload / creator (OBS, video calls, cloud backup): uplink capacity and its steadiness.
    public static let upload = ScoreProfile(
        weights: [.upload: 0.45, .uploadStability: 0.25, .uploadBloat: 0.15, .loss: 0.15],
        caps: [ScoreCap(metric: .upload, threshold: 3, whenBelow: true, maximumScore: 30),
               ScoreCap(metric: .loss, threshold: 5, maximumScore: 30)])

    /// Overall: balanced, with loss weighted like bandwidth because it breaks every use case.
    public static let overall = ScoreProfile(
        weights: [.download: 0.20, .upload: 0.15, .latency: 0.15, .jitter: 0.10, .loss: 0.20,
                  .downloadBloat: 0.05, .uploadBloat: 0.05, .downloadStability: 0.05, .uploadStability: 0.05],
        caps: [ScoreCap(metric: .loss, threshold: 5, maximumScore: 40), ScoreCap(metric: .jitter, threshold: 80, maximumScore: 50)])
}

public protocol ScoreEngineProtocol: Sendable {
    func scores(for metrics: MetricSnapshot) -> QualityScores
}

/// Scenario scoring.
///
/// For a profile with weights wₘ and sub-scores sₘ = curveₘ(rawₘ) over the *measured* metrics M:
///
///     coverage = Σ_{m∈M} wₘ / Σ_all wₘ           (no score if coverage < minimumCoverage)
///     score    = Σ_{m∈M} wₘ · sₘ / Σ_{m∈M} wₘ     (weights renormalised over measured metrics)
///     score    = min(score, cap.maximumScore)    for every triggered cap
///     result   = round(clamp(score, 0, 100))
///
/// Different weights per scenario mean the same connection can be 90 for streaming and 30 for
/// gaming — which is the point: this is not a plain average of all metrics.
public struct ScoreEngine: ScoreEngineProtocol {
    public init() {}

    static func raw(_ metric: ScoreMetric, _ m: MetricSnapshot) -> Double? {
        switch metric {
        case .download: m.downloadMbps
        case .upload: m.uploadMbps
        case .latency: m.idleLatencyMs
        case .jitter: m.jitterMs
        case .loss: m.lossPercent
        case .downloadBloat: m.downloadBloatMs
        case .uploadBloat: m.uploadBloatMs
        case .downloadStability: m.downloadStability
        case .uploadStability: m.uploadStability
        }
    }

    static func curve(_ metric: ScoreMetric) -> ScoreCurve {
        switch metric {
        case .download: .download
        case .upload: .upload
        case .latency: .latency
        case .jitter: .jitter
        case .loss: .loss
        case .downloadBloat, .uploadBloat: .bufferbloat
        case .downloadStability, .uploadStability: .identity
        }
    }

    public func score(_ metrics: MetricSnapshot, profile: ScoreProfile) -> Int? {
        let totalWeight = profile.weights.values.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        var weighted = 0.0
        var measuredWeight = 0.0
        for (metric, weight) in profile.weights {
            guard let value = Self.raw(metric, metrics) else { continue }
            weighted += weight * Self.curve(metric).score(value)
            measuredWeight += weight
        }
        guard measuredWeight / totalWeight >= profile.minimumCoverage else { return nil }

        var score = weighted / measuredWeight
        for cap in profile.caps {
            guard let value = Self.raw(cap.metric, metrics) else { continue }
            let triggered = cap.whenBelow ? value < cap.threshold : value >= cap.threshold
            if triggered { score = min(score, cap.maximumScore) }
        }
        return Int(Descriptive.clamp(score, 0...100).rounded())
    }

    public func scores(for metrics: MetricSnapshot) -> QualityScores {
        QualityScores(
            overall: score(metrics, profile: .overall),
            gaming: score(metrics, profile: .gaming),
            streaming: score(metrics, profile: .streaming),
            voice: score(metrics, profile: .voice),
            upload: score(metrics, profile: .upload))
    }
}
