import Foundation

/// Only values cross executors. SwiftData route models stay in their own context.
struct PerformancePoint: Sendable {
    var timestamp: Date
    var distance: Double
}
enum PerformanceWindow {
    static func fastest(points: [PerformancePoint], distance: Double) throws -> TimeInterval? {
        guard points.count > 1, distance.isFinite, distance > 0 else { return nil }
        var best: TimeInterval?
        var start = 0
        for end in 1..<points.count {
            if end % 1024 == 0 { try Task.checkCancellation() }
            // Raw observations can contain repeated/retrograde values. Do not bridge resets.
            guard points[end].distance.isFinite, points[end].timestamp > points[end - 1].timestamp,
                  points[end].distance >= points[end - 1].distance else { start = end; continue }
            while start < end && points[end].distance - points[start].distance >= distance {
                let duration = points[end].timestamp.timeIntervalSince(points[start].timestamp)
                if duration > 0 && (best == nil || duration < best!) { best = duration }
                start += 1
            }
        }
        return best
    }
}
