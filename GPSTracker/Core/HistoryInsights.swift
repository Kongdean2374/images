import Foundation

/// 全部紀錄（含匯入）的總覽分析
struct HistoryInsights {

    struct YearStat: Identifiable, Hashable {
        let id = UUID()
        let year: Int
        let distance: Double
        let duration: TimeInterval
        let count: Int
        let calories: Double
    }

    struct MonthStat: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let label: String
        let distance: Double
        let count: Int
    }

    struct SourceStat: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let count: Int
        let distance: Double
        let duration: TimeInterval
        let isLocal: Bool
    }

    var totalCount = 0
    var importedCount = 0
    var localCount = 0
    var totalDistance: Double = 0
    var totalDuration: TimeInterval = 0
    var totalCalories: Double = 0
    var totalSteps = 0
    var totalElevation: Double = 0
    var withRouteCount = 0
    var firstDate: Date?
    var lastDate: Date?
    var activeDays = 0
    var coverageDays = 0
    var years: [YearStat] = []
    var months: [MonthStat] = []
    var sources: [SourceStat] = []
    var typeShares: [TypeShare] = []
    var longestDistance: Double = 0
    var longestDuration: TimeInterval = 0
    var fastestPace: Double?
    var busiestYear: YearStat?

    var averagePerWeek: Double {
        guard coverageDays > 7 else { return Double(totalCount) }
        return Double(totalCount) / (Double(coverageDays) / 7)
    }

    var averageDistance: Double {
        totalCount > 0 ? totalDistance / Double(totalCount) : 0
    }

    var consistency: Double {
        coverageDays > 0 ? min(1, Double(activeDays) / Double(coverageDays)) : 0
    }
}

enum HistoryInsightsEngine {

    static func build(sessions: [WorkoutSession], calendar: Calendar = .current) -> HistoryInsights {
        var insights = HistoryInsights()
        guard !sessions.isEmpty else { return insights }

        insights.totalCount = sessions.count
        insights.importedCount = sessions.filter { $0.isImported }.count
        insights.localCount = insights.totalCount - insights.importedCount

        var yearMap: [Int: (distance: Double, duration: TimeInterval, count: Int, calories: Double)] = [:]
        var monthMap: [Date: (distance: Double, count: Int)] = [:]
        var sourceMap: [String: (count: Int, distance: Double, duration: TimeInterval, isLocal: Bool)] = [:]
        var days: Set<Date> = []

        for session in sessions {
            let distance = session.totalDistance ?? 0
            insights.totalDistance += distance
            insights.totalDuration += session.duration
            insights.totalCalories += session.calories ?? 0
            insights.totalSteps += session.stepCount ?? 0
            insights.totalElevation += session.elevationGain ?? 0
            if !session.routePoints.isEmpty { insights.withRouteCount += 1 }

            if insights.firstDate == nil || session.startDate < insights.firstDate! {
                insights.firstDate = session.startDate
            }
            if insights.lastDate == nil || session.startDate > insights.lastDate! {
                insights.lastDate = session.startDate
            }
            days.insert(calendar.startOfDay(for: session.startDate))

            let year = calendar.component(.year, from: session.startDate)
            var yearEntry = yearMap[year] ?? (0, 0, 0, 0)
            yearEntry.distance += distance
            yearEntry.duration += session.duration
            yearEntry.count += 1
            yearEntry.calories += session.calories ?? 0
            yearMap[year] = yearEntry

            if let monthKey = calendar.date(from: calendar.dateComponents([.year, .month], from: session.startDate)) {
                var monthEntry = monthMap[monthKey] ?? (0, 0)
                monthEntry.distance += distance
                monthEntry.count += 1
                monthMap[monthKey] = monthEntry
            }

            let sourceName = session.isImported ? (session.sourceApp ?? "健康 App") : "本機記錄"
            var sourceEntry = sourceMap[sourceName] ?? (0, 0, 0, !session.isImported)
            sourceEntry.count += 1
            sourceEntry.distance += distance
            sourceEntry.duration += session.duration
            sourceMap[sourceName] = sourceEntry

            if distance > insights.longestDistance { insights.longestDistance = distance }
            if session.duration > insights.longestDuration { insights.longestDuration = session.duration }
            if let pace = session.averagePace, pace > 120, distance > 800 {
                if insights.fastestPace == nil || pace < insights.fastestPace! {
                    insights.fastestPace = pace
                }
            }
        }

        insights.activeDays = days.count
        if let first = insights.firstDate, let last = insights.lastDate {
            insights.coverageDays = max(1, Int(last.timeIntervalSince(first) / 86400) + 1)
        }

        insights.years = yearMap
            .map { HistoryInsights.YearStat(year: $0.key,
                                            distance: $0.value.distance,
                                            duration: $0.value.duration,
                                            count: $0.value.count,
                                            calories: $0.value.calories) }
            .sorted { $0.year < $1.year }
        insights.busiestYear = insights.years.max { $0.distance < $1.distance }

        let recentMonths = monthMap.keys.sorted().suffix(24)
        insights.months = recentMonths.map { key in
            let entry = monthMap[key] ?? (0, 0)
            let month = calendar.component(.month, from: key)
            let year = calendar.component(.year, from: key) % 100
            return HistoryInsights.MonthStat(date: key,
                                             label: month == 1 ? "\(year)/1" : "\(month)",
                                             distance: entry.distance,
                                             count: entry.count)
        }

        insights.sources = sourceMap
            .map { HistoryInsights.SourceStat(name: $0.key,
                                              count: $0.value.count,
                                              distance: $0.value.distance,
                                              duration: $0.value.duration,
                                              isLocal: $0.value.isLocal) }
            .sorted { $0.count > $1.count }

        insights.typeShares = StatsEngine.typeDistribution(sessions: sessions)
        return insights
    }
}
