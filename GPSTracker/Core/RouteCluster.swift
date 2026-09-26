import Foundation
import CoreLocation

/// 自動辨識出來的「同一條路線」
struct RouteCluster: Identifiable, Hashable {
    let id = UUID()
    let signature: String
    let name: String
    let sessionIDs: [UUID]
    let count: Int
    let averageDistance: Double
    let bestPace: Double?
    let latestDate: Date
    let firstDate: Date
    let improvement: Double?   // 正值代表比第一次快的百分比

    static func == (lhs: RouteCluster, rhs: RouteCluster) -> Bool {
        lhs.signature == rhs.signature
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(signature)
    }
}

enum RouteClusterEngine {

    /// 起終點座標格點大小（約 150 公尺）
    private static let gridDegrees = 0.0015
    /// 距離分桶（公尺）
    private static let distanceBucket = 400.0

    private static func grid(_ value: Double) -> Int {
        Int((value / gridDegrees).rounded())
    }

    static func signature(for session: WorkoutSession) -> String? {
        let points = session.sortedPoints
        guard points.count > 5,
              let first = points.first,
              let last = points.last,
              let distance = session.totalDistance, distance > 500 else { return nil }

        let startKey = "\(grid(first.latitude))_\(grid(first.longitude))"
        let endKey = "\(grid(last.latitude))_\(grid(last.longitude))"
        let distanceKey = Int((distance / distanceBucket).rounded())
        return "\(startKey)|\(endKey)|\(distanceKey)"
    }

    /// 把有軌跡的紀錄自動分群，只回傳跑過兩次以上的路線
    static func cluster(sessions: [WorkoutSession]) -> [RouteCluster] {
        var groups: [String: [WorkoutSession]] = [:]
        for session in sessions {
            guard let key = signature(for: session) else { continue }
            groups[key, default: []].append(session)
        }

        return groups.compactMap { key, items -> RouteCluster? in
            guard items.count >= 2 else { return nil }
            let sorted = items.sorted { $0.startDate < $1.startDate }
            let distances = sorted.compactMap { $0.totalDistance }
            let averageDistance = distances.isEmpty ? 0 : distances.reduce(0, +) / Double(distances.count)
            let paces = sorted.compactMap { $0.averagePace }
            let improvement: Double? = {
                guard let first = paces.first, let last = paces.last, first > 0 else { return nil }
                return (first - last) / first * 100
            }()

            let name: String = {
                if let custom = sorted.compactMap({ $0.routeKey }).first(where: { !$0.isEmpty }) {
                    return custom
                }
                return String(format: "%.1f 公里路線", averageDistance / 1000)
            }()

            return RouteCluster(signature: key,
                                name: name,
                                sessionIDs: sorted.map { $0.id },
                                count: sorted.count,
                                averageDistance: averageDistance,
                                bestPace: paces.min(),
                                latestDate: sorted.last?.startDate ?? Date(),
                                firstDate: sorted.first?.startDate ?? Date(),
                                improvement: improvement)
        }
        .sorted { $0.count > $1.count }
    }

    /// 取回某個群組的實際場次
    static func sessions(in cluster: RouteCluster, from all: [WorkoutSession]) -> [WorkoutSession] {
        let ids = Set(cluster.sessionIDs)
        return all.filter { ids.contains($0.id) }.sorted { $0.startDate < $1.startDate }
    }
}
