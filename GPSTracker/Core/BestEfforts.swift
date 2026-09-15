import Foundation

/// 標準距離的最佳成績（從 GPS 軌跡用滑動視窗找出最快的一段）
struct BestEffort: Identifiable, Hashable {
    let id = UUID()
    let distance: Double        // 公尺
    let label: String
    let duration: TimeInterval
    let date: Date
    let sessionTitle: String

    var pace: Double {
        duration / (distance / 1000)
    }
}

enum BestEffortEngine {

    static let standardDistances: [(distance: Double, label: String)] = [
        (400, "400 公尺"),
        (1000, "1 公里"),
        (1609.344, "1 英里"),
        (3000, "3 公里"),
        (5000, "5 公里"),
        (10000, "10 公里"),
        (21097.5, "半程馬拉松")
    ]

    /// 在單一軌跡中找出跑完指定距離最快的一段
    static func fastestSegment(points: [RoutePoint], distance: Double) -> TimeInterval? {
        guard points.count > 1,
              let last = points.last,
              let first = points.first,
              last.distanceFromStart - first.distanceFromStart >= distance else { return nil }

        var best: TimeInterval?
        var start = 0
        for end in 1..<points.count {
            while points[end].distanceFromStart - points[start].distanceFromStart >= distance {
                let duration = points[end].timestamp.timeIntervalSince(points[start].timestamp)
                if duration > 0, best == nil || duration < best! {
                    best = duration
                }
                start += 1
                if start >= end { break }
            }
        }
        return best
    }

    /// 全部紀錄中每個標準距離的最佳成績
    static func evaluate(sessions: [WorkoutSession], limit: Int = 200) -> [BestEffort] {
        let routeSessions = sessions
            .filter { $0.routePoints.count > 2 }
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)

        var best: [Double: BestEffort] = [:]

        for session in routeSessions {
            let points = session.sortedPoints
            guard let total = points.last?.distanceFromStart, total > 300 else { continue }
            for item in standardDistances where item.distance <= total {
                guard let duration = fastestSegment(points: points, distance: item.distance) else { continue }
                let effort = BestEffort(distance: item.distance,
                                        label: item.label,
                                        duration: duration,
                                        date: session.startDate,
                                        sessionTitle: session.displayTitle)
                if let existing = best[item.distance] {
                    if duration < existing.duration { best[item.distance] = effort }
                } else {
                    best[item.distance] = effort
                }
            }
        }

        return best.values.sorted { $0.distance < $1.distance }
    }

    /// 單次運動的各距離最佳
    static func evaluate(session: WorkoutSession) -> [BestEffort] {
        let points = session.sortedPoints
        guard let total = points.last?.distanceFromStart else { return [] }
        return standardDistances.compactMap { item in
            guard item.distance <= total,
                  let duration = fastestSegment(points: points, distance: item.distance) else { return nil }
            return BestEffort(distance: item.distance,
                              label: item.label,
                              duration: duration,
                              date: session.startDate,
                              sessionTitle: session.displayTitle)
        }
    }
}

// MARK: - 配速區間

struct PaceZoneSlice: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let name: String
    let seconds: TimeInterval
    let lowerRatio: Double
    let upperRatio: Double

    var label: String {
        switch index {
        case 0: return "恢復"
        case 1: return "輕鬆"
        case 2: return "穩定"
        case 3: return "節奏"
        default: return "衝刺"
        }
    }
}

enum PaceZoneEngine {

    /// 以該次運動的平均配速為基準，切五個相對區間
    static func distribution(points: [RoutePoint], averagePace: Double?) -> [PaceZoneSlice] {
        guard points.count > 2, let average = averagePace, average > 0 else { return [] }

        // 區間以「相對平均配速的倍率」定義，倍率越小代表越快
        let bounds: [(Double, Double, String)] = [
            (1.18, .infinity, "恢復"),
            (1.08, 1.18, "輕鬆"),
            (0.98, 1.08, "穩定"),
            (0.90, 0.98, "節奏"),
            (0, 0.90, "衝刺")
        ]
        var seconds = [TimeInterval](repeating: 0, count: bounds.count)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let dt = current.timestamp.timeIntervalSince(previous.timestamp)
            guard dt > 0, dt < 30 else { continue }
            let dd = current.distanceFromStart - previous.distanceFromStart
            guard dd > 0.4 else { continue }
            let pace = dt / (dd / 1000)
            guard pace > 90, pace < 3600 else { continue }
            let ratio = pace / average
            for (zoneIndex, bound) in bounds.enumerated() where ratio >= bound.0 && ratio < bound.1 {
                seconds[zoneIndex] += dt
                break
            }
        }

        let total = seconds.reduce(0, +)
        guard total > 1 else { return [] }

        return bounds.enumerated().map { index, bound in
            PaceZoneSlice(index: index,
                          name: bound.2,
                          seconds: seconds[index],
                          lowerRatio: bound.0,
                          upperRatio: bound.1)
        }
    }
}
