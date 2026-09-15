import Foundation

struct DailyLoad: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let load: Double
    let sessions: Int
}

/// 訓練負荷分析（sRPE 法：自覺強度 × 分鐘數）
struct TrainingLoadReport {
    var daily: [DailyLoad] = []
    /// 近 7 天總負荷
    var acute: Double = 0
    /// 近 28 天的週平均負荷
    var chronic: Double = 0
    /// 急慢性負荷比（ACWR）
    var ratio: Double = 0
    /// 短期疲勞（7 天 EMA）
    var atl: Double = 0
    /// 長期體能（42 天 EMA）
    var ctl: Double = 0
    /// 狀態指數（體能 − 疲勞）
    var tsb: Double = 0
    var weeklyChange: Double = 0
    var restDays7: Int = 0
    var hasEnoughData = false

    enum Zone: String {
        case insufficient, detraining, optimal, caution, risk

        var displayName: String {
            switch self {
            case .insufficient: return "資料不足"
            case .detraining: return "訓練量偏低"
            case .optimal: return "最佳區間"
            case .caution: return "負荷偏高"
            case .risk: return "過度訓練風險"
            }
        }
    }

    var zone: Zone {
        guard hasEnoughData else { return .insufficient }
        switch ratio {
        case ..<0.8: return .detraining
        case ..<1.3: return .optimal
        case ..<1.5: return .caution
        default: return .risk
        }
    }

    var advice: String {
        switch zone {
        case .insufficient:
            return "再累積幾次紀錄（建議兩週以上）就能算出可靠的訓練負荷趨勢。"
        case .detraining:
            return "近期訓練量低於過去四週的水準，可以逐步增加時間或強度，每週增幅建議不超過 10%。"
        case .optimal:
            return "急慢性負荷比在 0.8～1.3 之間，屬於進步與風險平衡的區間，維持目前節奏即可。"
        case .caution:
            return "近期訓練量明顯高於過去四週，注意睡眠與補給，接下來安排一次輕鬆日。"
        case .risk:
            return "短期負荷遠高於身體已適應的水準，受傷風險升高，建議降量或安排休息日。"
        }
    }

    var formText: String {
        switch tsb {
        case ..<(-25): return "深度疲勞"
        case ..<(-10): return "疲勞累積"
        case ..<5: return "狀態平衡"
        case ..<20: return "恢復良好"
        default: return "過度休息"
        }
    }
}

enum TrainingLoadEngine {

    /// 單次訓練負荷：sRPE（1-10）× 分鐘數。沒有 RPE 時用強度分數換算。
    static func load(for session: WorkoutSession) -> Double {
        let minutes = session.duration / 60
        guard minutes > 0 else { return 0 }
        let rpe: Double
        if let value = session.rpe, value > 0 {
            rpe = Double(value)
        } else if let score = session.intensityScore {
            rpe = min(10, max(1, score / 10))
        } else {
            rpe = 5
        }
        return rpe * minutes
    }

    static func report(sessions: [WorkoutSession], days: Int = 90, calendar: Calendar = .current) -> TrainingLoadReport {
        var report = TrainingLoadReport()
        guard !sessions.isEmpty else { return report }

        let today = calendar.startOfDay(for: Date())
        var byDay: [Date: (load: Double, count: Int)] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            var entry = byDay[day] ?? (0, 0)
            entry.load += load(for: session)
            entry.count += 1
            byDay[day] = entry
        }

        var daily: [DailyLoad] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let entry = byDay[day] ?? (0, 0)
            daily.append(DailyLoad(date: day, load: entry.load, sessions: entry.count))
        }
        report.daily = daily

        let last7 = daily.suffix(7)
        let last28 = daily.suffix(28)
        report.acute = last7.reduce(0) { $0 + $1.load }
        report.chronic = last28.reduce(0) { $0 + $1.load } / 4
        report.ratio = report.chronic > 0 ? report.acute / report.chronic : 0
        report.restDays7 = last7.filter { $0.load <= 0 }.count

        let previous7 = daily.dropLast(7).suffix(7).reduce(0) { $0 + $1.load }
        report.weeklyChange = previous7 > 0 ? (report.acute - previous7) / previous7 : 0

        // 指數移動平均：ATL 7 天、CTL 42 天
        var atl = 0.0
        var ctl = 0.0
        let atlFactor = 2.0 / (7 + 1)
        let ctlFactor = 2.0 / (42 + 1)
        for day in daily {
            atl = day.load * atlFactor + atl * (1 - atlFactor)
            ctl = day.load * ctlFactor + ctl * (1 - ctlFactor)
        }
        report.atl = atl
        report.ctl = ctl
        report.tsb = ctl - atl

        let activeDays = daily.filter { $0.load > 0 }.count
        report.hasEnoughData = activeDays >= 5 && report.chronic > 0

        return report
    }

    /// 每週負荷彙總（給長條圖用）
    static func weekly(sessions: [WorkoutSession], weeks: Int = 12, calendar: Calendar = .current) -> [TrendBucket] {
        var buckets: [Date: (load: Double, count: Int, duration: TimeInterval, distance: Double)] = [:]
        for session in sessions {
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: session.startDate)
            guard let key = calendar.date(from: comps) else { continue }
            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry.load += load(for: session)
            entry.count += 1
            entry.duration += session.duration
            entry.distance += session.totalDistance ?? 0
            buckets[key] = entry
        }
        let now = Date()
        var result: [TrendBucket] = []
        for offset in stride(from: weeks - 1, through: 0, by: -1) {
            guard let base = calendar.date(byAdding: .weekOfYear, value: -offset, to: now),
                  let key = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: base))
            else { continue }
            let entry = buckets[key] ?? (0, 0, 0, 0)
            result.append(TrendBucket(date: key,
                                      label: Fmt.shortDayFormatter.string(from: key),
                                      totalDistance: entry.distance,
                                      totalDuration: entry.duration,
                                      count: entry.count,
                                      averagePace: nil,
                                      intensity: entry.load))
        }
        return result
    }
}
