import Foundation

// MARK: - 分段資料

struct SplitSegment: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let label: String
    /// 公尺
    let distance: Double
    let duration: TimeInterval
    /// 秒/公里
    let pace: Double?
    let elevationGain: Double
    /// 對應軌跡點索引範圍（無定位模式為 nil）
    let pointRange: ClosedRange<Int>?
    let isPartial: Bool
}

struct TrendBucket: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let label: String
    let totalDistance: Double
    let totalDuration: TimeInterval
    let count: Int
    let averagePace: Double?
    let intensity: Double
}

struct TypeShare: Identifiable, Hashable {
    let id = UUID()
    let type: WorkoutType
    let count: Int
    let duration: TimeInterval
    let distance: Double
}

struct PersonalRecords {
    var fastestPace: (value: Double, session: WorkoutSession)?
    var longestDistance: (value: Double, session: WorkoutSession)?
    var longestDuration: (value: TimeInterval, session: WorkoutSession)?
    var highestClimb: (value: Double, session: WorkoutSession)?
    var bestIntensity: (value: Double, session: WorkoutSession)?
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var totalDistance: Double = 0
    var totalDuration: TimeInterval = 0
    var totalSessions: Int = 0
}

enum TrendRange: String, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .week: return "週"
        case .month: return "月"
        case .year: return "年"
        }
    }
    /// 顯示的區間數量
    var bucketCount: Int {
        switch self {
        case .week: return 12
        case .month: return 12
        case .year: return 5
        }
    }
}

// MARK: - 統計引擎

enum StatsEngine {

    // MARK: 分段配速

    /// 依總距離挑一個合理的分段長度。
    ///
    /// 固定切每公里的話，不到一公里的紀錄只會得到一根佔滿整張圖的長條，
    /// 什麼也看不出來。短距離自動改用較細的分段。
    static func adaptiveSplitDistance(for totalDistance: Double) -> Double {
        switch totalDistance {
        case ..<600: return 100
        case ..<1_500: return 200
        case ..<4_000: return 500
        case ..<25_000: return 1_000
        default: return 5_000
        }
    }

    /// GPS 模式：每公里切段（依 splitDistance 公尺）。
    /// 傳 nil 代表依總距離自動決定分段長度。
    static func splits(for session: WorkoutSession, splitDistance: Double? = nil) -> [SplitSegment] {
        let step = splitDistance
            ?? adaptiveSplitDistance(for: session.totalDistance ?? 0)
        if session.type.requiresLocation && session.hasRoute {
            return gpsSplits(points: session.sortedPoints, splitDistance: step)
        }
        if !session.laps.isEmpty {
            return lapSplits(laps: session.sortedLaps)
        }
        return []
    }

    static func gpsSplits(points: [RoutePoint], splitDistance: Double) -> [SplitSegment] {
        guard points.count > 1 else { return [] }
        var result: [SplitSegment] = []
        var startIdx = 0
        var splitIndex = 1
        var nextMark = splitDistance

        for i in 1..<points.count {
            let p = points[i]
            if p.distanceFromStart >= nextMark || i == points.count - 1 {
                let start = points[startIdx]
                let dist = p.distanceFromStart - start.distanceFromStart
                let dur = p.timestamp.timeIntervalSince(start.timestamp)
                guard dist > 1, dur > 0 else {
                    startIdx = i
                    nextMark += splitDistance
                    continue
                }
                var gain = 0.0
                if startIdx < i {
                    for j in (startIdx + 1)...i {
                        let d = points[j].altitude - points[j - 1].altitude
                        if d > 0 { gain += d }
                    }
                }
                let partial = dist < splitDistance * 0.92
                result.append(SplitSegment(index: splitIndex,
                                           label: partial
                                                ? String(format: "%.2f km", dist / 1000)
                                                : "第 \(splitIndex) 公里",
                                           distance: dist,
                                           duration: dur,
                                           pace: dur / (dist / 1000),
                                           elevationGain: gain,
                                           pointRange: startIdx...i,
                                           isPartial: partial))
                splitIndex += 1
                startIdx = i
                nextMark = p.distanceFromStart + splitDistance
            }
        }
        return result
    }

    static func lapSplits(laps: [LapRecord]) -> [SplitSegment] {
        laps.map { lap in
            SplitSegment(index: lap.lapNumber,
                         label: "第 \(lap.lapNumber) 圈",
                         distance: lap.distanceOverride ?? 0,
                         duration: lap.lapDuration,
                         pace: lap.pace,
                         elevationGain: 0,
                         pointRange: nil,
                         isPartial: false)
        }
    }

    // MARK: 趨勢

    static func trend(sessions: [WorkoutSession], range: TrendRange, calendar: Calendar = .current) -> [TrendBucket] {
        guard !sessions.isEmpty else { return [] }
        var buckets: [Date: [WorkoutSession]] = [:]
        for s in sessions {
            let key = bucketStart(for: s.startDate, range: range, calendar: calendar)
            buckets[key, default: []].append(s)
        }
        let now = Date()
        var keys: [Date] = []
        for i in stride(from: range.bucketCount - 1, through: 0, by: -1) {
            let base: Date?
            switch range {
            case .week: base = calendar.date(byAdding: .weekOfYear, value: -i, to: now)
            case .month: base = calendar.date(byAdding: .month, value: -i, to: now)
            case .year: base = calendar.date(byAdding: .year, value: -i, to: now)
            }
            if let base { keys.append(bucketStart(for: base, range: range, calendar: calendar)) }
        }
        return keys.map { key in
            let items = buckets[key] ?? []
            let dist = items.reduce(0.0) { $0 + ($1.totalDistance ?? 0) }
            let dur = items.reduce(0.0) { $0 + $1.duration }
            let paced = items.compactMap { $0.averagePace }
            let intensity = items.compactMap { $0.intensityScore }
            return TrendBucket(date: key,
                               label: label(for: key, range: range),
                               totalDistance: dist,
                               totalDuration: dur,
                               count: items.count,
                               averagePace: paced.isEmpty ? nil : paced.reduce(0, +) / Double(paced.count),
                               intensity: intensity.isEmpty ? 0 : intensity.reduce(0, +) / Double(intensity.count))
        }
    }

    static func bucketStart(for date: Date, range: TrendRange, calendar: Calendar = .current) -> Date {
        switch range {
        case .week:
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: comps) ?? date
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: comps) ?? date
        case .year:
            let comps = calendar.dateComponents([.year], from: date)
            return calendar.date(from: comps) ?? date
        }
    }

    static func label(for date: Date, range: TrendRange) -> String {
        let calendar = Calendar.current
        switch range {
        case .week:
            return Fmt.shortDayFormatter.string(from: date)
        case .month:
            let month = calendar.component(.month, from: date)
            // 一月標上年份，其餘只留月份，避免 X 軸文字擠在一起
            if month == 1 {
                let year = calendar.component(.year, from: date) % 100
                return "\(year)/1"
            }
            return "\(month)月"
        case .year:
            return "\(calendar.component(.year, from: date))"
        }
    }

    // MARK: 類型分佈

    static func typeDistribution(sessions: [WorkoutSession]) -> [TypeShare] {
        var map: [WorkoutType: (Int, TimeInterval, Double)] = [:]
        for s in sessions {
            var entry = map[s.type] ?? (0, 0, 0)
            entry.0 += 1
            entry.1 += s.duration
            entry.2 += s.totalDistance ?? 0
            map[s.type] = entry
        }
        return map.map { TypeShare(type: $0.key, count: $0.value.0, duration: $0.value.1, distance: $0.value.2) }
            .sorted { $0.duration > $1.duration }
    }

    // MARK: 個人紀錄

    static func personalRecords(sessions: [WorkoutSession], calendar: Calendar = .current) -> PersonalRecords {
        var pb = PersonalRecords()
        guard !sessions.isEmpty else { return pb }

        for s in sessions {
            if let pace = s.averagePace, pace > 120, (s.totalDistance ?? 0) > 400 {
                if pb.fastestPace == nil || pace < pb.fastestPace!.value { pb.fastestPace = (pace, s) }
            }
            if let dist = s.totalDistance, dist > 0 {
                if pb.longestDistance == nil || dist > pb.longestDistance!.value { pb.longestDistance = (dist, s) }
            }
            if s.duration > 0 {
                if pb.longestDuration == nil || s.duration > pb.longestDuration!.value { pb.longestDuration = (s.duration, s) }
            }
            if let gain = s.elevationGain, gain > 0 {
                if pb.highestClimb == nil || gain > pb.highestClimb!.value { pb.highestClimb = (gain, s) }
            }
            if let score = s.intensityScore {
                if pb.bestIntensity == nil || score > pb.bestIntensity!.value { pb.bestIntensity = (score, s) }
            }
            pb.totalDistance += s.totalDistance ?? 0
            pb.totalDuration += s.duration
        }
        pb.totalSessions = sessions.count

        let days = Set(sessions.map { calendar.startOfDay(for: $0.startDate) }).sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for day in days {
            if let prev = previous, let next = calendar.date(byAdding: .day, value: 1, to: prev), calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        pb.longestStreak = longest

        // 目前連續天數（今天或昨天有運動才算延續）
        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        let daySet = Set(days)
        if !daySet.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while daySet.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        pb.currentStreak = streak
        return pb
    }

    /// 判斷本次運動是否刷新紀錄（用於慶祝動畫）
    static func newRecords(for session: WorkoutSession, among others: [WorkoutSession]) -> [String] {
        let history = others.filter { $0.id != session.id }
        var titles: [String] = []
        if let dist = session.totalDistance, dist > 0,
           history.allSatisfy({ ($0.totalDistance ?? 0) < dist }) {
            titles.append("最長距離")
        }
        if let pace = session.averagePace, pace > 120, (session.totalDistance ?? 0) > 400,
           history.compactMap({ $0.averagePace }).allSatisfy({ $0 > pace }) {
            titles.append("最快平均配速")
        }
        if session.duration > 0, history.allSatisfy({ $0.duration < session.duration }) {
            titles.append("最長運動時間")
        }
        if let gain = session.elevationGain, gain > 10,
           history.compactMap({ $0.elevationGain }).allSatisfy({ $0 < gain }) {
            titles.append("最大累積爬升")
        }
        return titles
    }

    // MARK: 目標進度

    static func progress(for goal: WorkoutGoal, sessions: [WorkoutSession], calendar: Calendar = .current) -> (current: Double, target: Double, fraction: Double) {
        let now = Date()
        let start: Date
        switch goal.period {
        case .weekly:
            start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        case .monthly:
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        }
        let inRange = sessions.filter { $0.startDate >= start && $0.startDate <= now }
        let current: Double
        switch goal.metric {
        case .distance: current = inRange.reduce(0.0) { $0 + ($1.totalDistance ?? 0) } / 1000
        case .count: current = Double(inRange.count)
        case .duration: current = inRange.reduce(0.0) { $0 + $1.duration } / 60
        }
        let fraction = goal.target > 0 ? min(1.0, current / goal.target) : 0
        return (current, goal.target, fraction)
    }

    // MARK: 同路線比較

    /// 以 routeKey 分組，找出可比較的群組（同組至少 2 筆）
    static func comparableGroups(sessions: [WorkoutSession]) -> [String: [WorkoutSession]] {
        var map: [String: [WorkoutSession]] = [:]
        for s in sessions {
            guard let key = s.routeKey, !key.isEmpty else { continue }
            map[key, default: []].append(s)
        }
        return map.filter { $0.value.count >= 2 }
            .mapValues { $0.sorted { $0.startDate < $1.startDate } }
    }

    /// 進步曲線：回傳每次的平均配速（秒/公里）
    static func progressCurve(_ sessions: [WorkoutSession]) -> [(Date, Double)] {
        sessions.compactMap { s in
            guard let pace = s.averagePace else { return nil }
            return (s.startDate, pace)
        }
    }

    // MARK: 天氣關聯

    struct WeatherPoint: Identifiable, Hashable {
        let id = UUID()
        let temperature: Double
        let pace: Double
        let note: String
        let date: Date
    }

    static func weatherCorrelation(sessions: [WorkoutSession]) -> [WeatherPoint] {
        sessions.compactMap { s in
            guard let t = s.temperature, let p = s.averagePace else { return nil }
            return WeatherPoint(temperature: t, pace: p, note: s.weatherNote ?? "", date: s.startDate)
        }
    }
}
