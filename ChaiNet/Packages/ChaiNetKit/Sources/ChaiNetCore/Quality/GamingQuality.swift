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

    public static func evaluate(idle: LatencyStatistics, loaded: LatencyStatistics?, spikes: [LatencySpikeEvent],
                                packetsPerSecond: Double, downloadMbps: Double?, score: Int?) -> GamingQualityResult {
        let reference = (loaded?.rtt != nil ? loaded : nil) ?? idle
        let p95 = reference.rtt?.p95 ?? 1000
        let jitter = reference.rtt?.jitter ?? 1000
        let loss = max(idle.loss.lossPercent, loaded?.loss.lossPercent ?? 0)
        let verdicts = GameGenre.allCases.map {
            verdict(for: $0, latencyP95: p95, jitter: jitter, lossPercent: loss, downloadMbps: downloadMbps)
        }
        return GamingQualityResult(idle: idle, loaded: loaded, spikes: spikes, packetsPerSecond: packetsPerSecond, verdicts: verdicts, score: score)
    }
}
