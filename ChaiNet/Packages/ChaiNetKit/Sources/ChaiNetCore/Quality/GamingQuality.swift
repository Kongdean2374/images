import Foundation

public enum GameGenre: String, Codable, Sendable, Hashable, CaseIterable {
    case competitiveShooter
    case fighting
    case moba
    case battleRoyale
    case mmo
    case cloudGaming
    case casual

    public var displayName: String {
        switch self {
        case .competitiveShooter: "競技 FPS"
        case .fighting: "格鬥遊戲"
        case .moba: "MOBA"
        case .battleRoyale: "大逃殺"
        case .mmo: "MMO / RPG"
        case .cloudGaming: "雲端遊戲"
        case .casual: "休閒 / 回合制"
        }
    }

    /// Thresholds for a "good" experience: (latency P95 ms, jitter ms, loss %, min download Mbps).
    public var requirements: GameRequirements {
        switch self {
        case .competitiveShooter: GameRequirements(maxLatencyMs: 50, maxJitterMs: 10, maxLossPercent: 0.5, minDownloadMbps: 3)
        case .fighting: GameRequirements(maxLatencyMs: 60, maxJitterMs: 8, maxLossPercent: 0.5, minDownloadMbps: 2)
        case .moba: GameRequirements(maxLatencyMs: 80, maxJitterMs: 15, maxLossPercent: 1, minDownloadMbps: 2)
        case .battleRoyale: GameRequirements(maxLatencyMs: 70, maxJitterMs: 15, maxLossPercent: 1, minDownloadMbps: 5)
        case .mmo: GameRequirements(maxLatencyMs: 120, maxJitterMs: 25, maxLossPercent: 2, minDownloadMbps: 3)
        case .cloudGaming: GameRequirements(maxLatencyMs: 40, maxJitterMs: 10, maxLossPercent: 0.5, minDownloadMbps: 35)
        case .casual: GameRequirements(maxLatencyMs: 200, maxJitterMs: 50, maxLossPercent: 3, minDownloadMbps: 1)
        }
    }
}

public struct GameRequirements: Codable, Sendable, Hashable {
    public var maxLatencyMs: Double
    public var maxJitterMs: Double
    public var maxLossPercent: Double
    public var minDownloadMbps: Double
}

public enum SuitabilityVerdict: String, Codable, Sendable, Hashable, Comparable {
    case great, playable, degraded, unsuitable

    private var rank: Int { [.great, .playable, .degraded, .unsuitable].firstIndex(of: self)! }
    public static func < (lhs: SuitabilityVerdict, rhs: SuitabilityVerdict) -> Bool { lhs.rank < rhs.rank }
}

public struct GenreVerdict: Codable, Sendable, Hashable, Identifiable {
    public var genre: GameGenre
    public var verdict: SuitabilityVerdict
    public var limitingFactors: [String]
    public var id: GameGenre { genre }
}

public struct GamingQualityResult: Codable, Sendable, Hashable {
    public var idle: LatencyStatistics
    /// Same probe while a download saturates the link (nil if skipped).
    public var loaded: LatencyStatistics?
    public var spikes: [LatencySpikeEvent]
    public var packetsPerSecond: Double
    public var verdicts: [GenreVerdict]
    public var score: Int?
    /// Path the verdicts are based on (best healthy regional path; nil in older results).
    public var referencePath: String?
    /// Every candidate path that was considered.
    public var pathCandidates: [GamingPathCandidate]?
}

/// One measured path to a latency endpoint (primary server or a cross-validation endpoint).
public struct GamingPathCandidate: Codable, Sendable, Hashable {
    public var name: String
    public var host: String
    public var method: String
    public var medianMs: Double?
    public var p95Ms: Double?
    public var jitterMs: Double?
    public var lossPercent: Double
    public var replies: Int
    public var isPrimary: Bool

    public init(name: String, host: String, method: String, statistics: LatencyStatistics, isPrimary: Bool) {
        self.name = name
        self.host = host
        self.method = method
        self.medianMs = statistics.rtt?.median
        self.p95Ms = statistics.rtt?.p95
        self.jitterMs = statistics.rtt?.jitter
        self.lossPercent = statistics.loss.lossPercent
        self.replies = statistics.loss.received
        self.isPrimary = isPrimary
    }

    /// Healthy = ≥ 10 replies and < 2 % loss. Unhealthy endpoints are shown but never chosen.
    public var isHealthy: Bool { replies >= 10 && lossPercent < 2 && p95Ms != nil }
}

/// Per-genre verdict.
///
/// Each metric is compared with the genre's requirement and rated by the ratio
/// `value / limit` (for download: `limit / value`):
///
///     ratio ≤ 1     → great
///     ratio ≤ 1.5   → playable
///     ratio ≤ 2.5   → degraded
///     ratio > 2.5   → unsuitable
///
/// The verdict is the worst rating across metrics. Latency uses P95 (a game feels its worst
/// moments, not its average). If a loaded measurement exists, the loaded P95 is used because
/// games usually share the link with other traffic.
public enum GamingQualityCalculator {
    static func rate(_ ratio: Double) -> SuitabilityVerdict {
        switch ratio {
        case ...1: .great
        case ...1.5: .playable
        case ...2.5: .degraded
        default: .unsuitable
        }
    }

    public static func verdict(for genre: GameGenre, latencyP95: Double, jitter: Double, lossPercent: Double, downloadMbps: Double?) -> GenreVerdict {
        let req = genre.requirements
        var worst = SuitabilityVerdict.great
        var factors: [String] = []

        func consider(_ name: String, _ ratio: Double) {
            let v = rate(ratio)
            if v > .great { factors.append(name) }
            worst = max(worst, v)
        }
        consider("延遲", latencyP95 / req.maxLatencyMs)
        consider("抖動", jitter / max(req.maxJitterMs, 0.001))
        // Loss: a zero requirement would divide by zero; limits are always > 0 here.
        consider("封包遺失", lossPercent / req.maxLossPercent)
        if let dl = downloadMbps {
            consider("頻寬", dl > 0 ? req.minDownloadMbps / dl : .infinity)
        }
        return GenreVerdict(genre: genre, verdict: worst, limitingFactors: factors)
    }

    /// Picks the best healthy regional path: a game connects to its nearest healthy server, so a
    /// single slow or ICMP-rate-limited endpoint (e.g. one Anycast ICMP target) must not decide
    /// the verdict. Lowest P95 among healthy candidates; nil when none is healthy.
    public static func bestPath(_ candidates: [GamingPathCandidate]) -> GamingPathCandidate? {
        candidates.filter(\.isHealthy).min { ($0.p95Ms ?? .infinity) < ($1.p95Ms ?? .infinity) }
    }

    /// Verdicts use the best healthy path. Load impact is carried over from the primary path:
    ///
    ///     p95    = best.p95 + max(0, loaded.p95 − primaryIdle.p95)
    ///     jitter = max(best.jitter, loaded.jitter)
    ///     loss   = max(best.loss, loaded.loss)
    ///
    /// With no alternative candidates this reduces to the primary path (previous behaviour).
    public static func evaluate(idle: LatencyStatistics, loaded: LatencyStatistics?, spikes: [LatencySpikeEvent],
                                packetsPerSecond: Double, downloadMbps: Double?, score: Int?,
                                alternatives: [GamingPathCandidate] = [], primaryName: String = "主要伺服器") -> GamingQualityResult {
        let primary = GamingPathCandidate(name: primaryName, host: "", method: "primary", statistics: idle, isPrimary: true)
        let candidates = [primary] + alternatives
        let best = alternatives.isEmpty ? nil : bestPath(candidates)
        let loadedStats = loaded?.rtt != nil ? loaded : nil
        let p95: Double
        let jitter: Double
        let loss: Double
        if let best, let bestP95 = best.p95Ms {
            let inflation = max(0, (loadedStats?.rtt?.p95 ?? 0) - (idle.rtt?.p95 ?? loadedStats?.rtt?.p95 ?? 0))
            p95 = bestP95 + inflation
            jitter = max(best.jitterMs ?? 1000, loadedStats?.rtt?.jitter ?? 0)
            loss = max(best.lossPercent, loadedStats?.loss.lossPercent ?? 0)
        } else {
            let reference = loadedStats ?? idle
            p95 = reference.rtt?.p95 ?? 1000
            jitter = reference.rtt?.jitter ?? 1000
            loss = max(idle.loss.lossPercent, loaded?.loss.lossPercent ?? 0)
        }
        let verdicts = GameGenre.allCases.map {
            verdict(for: $0, latencyP95: p95, jitter: jitter, lossPercent: loss, downloadMbps: downloadMbps)
        }
        return GamingQualityResult(idle: idle, loaded: loaded, spikes: spikes, packetsPerSecond: packetsPerSecond, verdicts: verdicts, score: score,
                                   referencePath: best.map { "\($0.name)\($0.host.isEmpty ? "" : " (\($0.host))")" } ?? primaryName,
                                   pathCandidates: alternatives.isEmpty ? nil : candidates)
    }
}
