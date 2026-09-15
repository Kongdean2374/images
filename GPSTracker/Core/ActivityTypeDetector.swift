import Foundation
import CoreMotion

/// 動作型態（靜止／走路／跑步／騎車／交通工具），不需要定位。
enum MotionKind: String, Codable, CaseIterable {
    case stationary, walking, running, cycling, automotive, unknown

    var displayName: String {
        switch self {
        case .stationary: return "靜止"
        case .walking: return "走路"
        case .running: return "跑步"
        case .cycling: return "騎車"
        case .automotive: return "交通工具"
        case .unknown: return "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .stationary: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .automotive: return "car.fill"
        case .unknown: return "questionmark"
        }
    }
}

final class ActivityTypeDetector: ObservableObject {
    struct Segment: Identifiable, Hashable {
        let id = UUID()
        var kind: MotionKind
        var start: Date
        var end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    @Published var current: MotionKind = .unknown
    @Published var confidence: Int = 0
    @Published var segments: [Segment] = []
    @Published var isRunning = false

    private let manager = CMMotionActivityManager()

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard CMMotionActivityManager.isActivityAvailable(), !isRunning else { return }
        isRunning = true
        segments = []
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let kind = Self.kind(for: activity)
            let level = activity.confidence.rawValue
            DispatchQueue.main.async {
                self?.ingest(kind: kind, confidence: level, at: activity.startDate)
            }
        }
    }

    func stop() {
        manager.stopActivityUpdates()
        isRunning = false
        closeLastSegment(at: Date())
    }

    private func ingest(kind: MotionKind, confidence level: Int, at date: Date) {
        confidence = level
        guard kind != .unknown else { return }
        if current != kind {
            closeLastSegment(at: date)
            segments.append(Segment(kind: kind, start: date, end: date))
            current = kind
        } else if var last = segments.last {
            last.end = date
            segments[segments.count - 1] = last
        }
    }

    private func closeLastSegment(at date: Date) {
        guard var last = segments.last, last.end < date else { return }
        last.end = date
        segments[segments.count - 1] = last
    }

    /// 走路 / 跑步各佔多少秒
    func durations() -> (walking: TimeInterval, running: TimeInterval) {
        var walking: TimeInterval = 0
        var running: TimeInterval = 0
        for segment in segments {
            switch segment.kind {
            case .walking: walking += segment.duration
            case .running: running += segment.duration
            default: break
            }
        }
        return (walking, running)
    }

    private static func kind(for activity: CMMotionActivity) -> MotionKind {
        if activity.running { return .running }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    /// 回溯查詢歷史動作紀錄（系統保留約 7 天）
    static func query(from start: Date, to end: Date) async -> [CMMotionActivity] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        let manager = CMMotionActivityManager()
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                continuation.resume(returning: activities ?? [])
            }
        }
    }
}
