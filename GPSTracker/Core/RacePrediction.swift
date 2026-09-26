import Foundation

/// 用最佳分段推估各距離的比賽成績（Riegel 公式）
struct RacePrediction: Identifiable, Hashable {
    let id = UUID()
    let distance: Double        // 公尺
    let label: String
    let predictedTime: TimeInterval
    let pace: Double            // 秒/公里
    /// 0...1，越高代表推估越可信
    let confidence: Double
    let basedOnLabel: String
    let basedOnDate: Date

    var confidenceText: String {
        switch confidence {
        case ..<0.35: return "僅供參考"
        case ..<0.6: return "粗略"
        case ..<0.8: return "還算可靠"
        default: return "可信度高"
        }
    }
}

enum RacePredictionEngine {

    static let targets: [(distance: Double, label: String)] = [
        (1000, "1 公里"),
        (3000, "3 公里"),
        (5000, "5 公里"),
        (10000, "10 公里"),
        (21097.5, "半程馬拉松"),
        (42195, "全程馬拉松")
    ]

    /// Riegel：T2 = T1 × (D2 / D1) ^ 1.06
    static func riegel(time: TimeInterval, from: Double, to: Double, exponent: Double = 1.06) -> TimeInterval {
        guard from > 0, to > 0 else { return 0 }
        return time * pow(to / from, exponent)
    }

    /// 以最佳分段為基礎推估各距離成績
    static func predictions(from efforts: [BestEffort]) -> [RacePrediction] {
        guard !efforts.isEmpty else { return [] }

        return targets.compactMap { target in
            // 選一個最適合當基礎的成績：距離接近、時間新、距離夠長
            let scored = efforts.map { effort -> (effort: BestEffort, score: Double) in
                let ratio = max(effort.distance, target.distance) / min(effort.distance, target.distance)
                // 距離差距越大越不準（Riegel 在 2 倍以內最穩）
                let distanceScore = 1 / (1 + log(max(1, ratio)))
                let ageDays = max(0, Date().timeIntervalSince(effort.date) / 86400)
                let freshness = pow(0.5, ageDays / 180)
                // 基礎距離太短推長距離會過度樂觀
                let lengthScore = min(1, effort.distance / 3000)
                return (effort, distanceScore * 0.5 + freshness * 0.3 + lengthScore * 0.2)
            }
            guard let best = scored.max(by: { $0.score < $1.score })?.effort,
                  let bestScore = scored.max(by: { $0.score < $1.score })?.score else { return nil }

            let time = riegel(time: best.duration, from: best.distance, to: target.distance)
            guard time > 0, time < 60 * 60 * 12 else { return nil }

            // 外推幅度越大信心越低
            let ratio = max(best.distance, target.distance) / min(best.distance, target.distance)
            let extrapolationPenalty = min(1, max(0, (ratio - 1) / 6))
            let confidence = max(0.1, min(1, bestScore * (1 - extrapolationPenalty * 0.7)))

            return RacePrediction(distance: target.distance,
                                  label: target.label,
                                  predictedTime: time,
                                  pace: time / (target.distance / 1000),
                                  confidence: confidence,
                                  basedOnLabel: best.label,
                                  basedOnDate: best.date)
        }
    }
}

// MARK: - 訓練強度分佈（80/20）

struct IntensityBalance {
    var easySeconds: TimeInterval = 0
    var moderateSeconds: TimeInterval = 0
    var hardSeconds: TimeInterval = 0
    var sessionCount = 0

    var total: TimeInterval {
        max(1, easySeconds + moderateSeconds + hardSeconds)
    }

    var easyRatio: Double { easySeconds / total }
    var moderateRatio: Double { moderateSeconds / total }
    var hardRatio: Double { hardSeconds / total }

    var hasEnoughData: Bool { sessionCount >= 5 }

    /// 與 80/20 原則的差距
    var verdict: String {
        guard hasEnoughData else { return "資料還不夠判斷" }
        switch easyRatio {
        case ..<0.55: return "高強度偏多"
        case ..<0.72: return "略偏高強度"
        case ..<0.88: return "接近 80/20"
        default: return "幾乎都是輕鬆跑"
        }
    }

    var advice: String {
        guard hasEnoughData else {
            return "再累積幾次有配速資料的訓練，就能看出你的輕鬆／高強度比例。"
        }
        switch easyRatio {
        case ..<0.55:
            return "高強度佔比偏高，容易累積疲勞。多數耐力訓練建議把約八成時間放在能輕鬆說話的強度。"
        case ..<0.72:
            return "高強度比例稍高。把一兩次課表換成輕鬆跑，恢復會更好，長期進步也更穩。"
        case ..<0.88:
            return "輕鬆與高強度的比例接近 80/20，是相當理想的分配。"
        default:
            return "幾乎都是輕鬆強度。每週安排一到兩次節奏跑或間歇，能有效提升配速上限。"
        }
    }
}

enum IntensityBalanceEngine {

    /// 以每次運動自己的配速區間分佈聚合
    static func evaluate(sessions: [WorkoutSession], days: Int = 90) -> IntensityBalance {
        var balance = IntensityBalance()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast

        for session in sessions where session.startDate >= cutoff {
            // 有軌跡的用配速區間，沒有軌跡的用強度分數粗分
            if session.routePoints.count > 5, let average = session.averagePace {
                let slices = PaceZoneEngine.distribution(points: session.sortedPoints, averagePace: average)
                guard !slices.isEmpty else { continue }
                balance.sessionCount += 1
                for slice in slices {
                    switch slice.index {
                    case 0, 1: balance.easySeconds += slice.seconds
                    case 2: balance.moderateSeconds += slice.seconds
                    default: balance.hardSeconds += slice.seconds
                    }
                }
            } else if let score = session.intensityScore, session.duration > 60 {
                balance.sessionCount += 1
                switch score {
                case ..<40: balance.easySeconds += session.duration
                case ..<65: balance.moderateSeconds += session.duration
                default: balance.hardSeconds += session.duration
                }
            }
        }
        return balance
    }
}
