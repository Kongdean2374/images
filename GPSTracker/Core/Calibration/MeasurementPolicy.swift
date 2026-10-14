import Foundation

enum MeasurementMethod: String, Codable, Sendable {
    case independentGPS, knownDistance, strideEstimate, systemEstimate, mixed, unknown
    var label: String {
        switch self {
        case .independentGPS: return "GPS 獨立實測"
        case .knownDistance: return "已確認外部實測距離"
        case .strideEstimate: return "步幅估算"
        case .systemEstimate: return "系統估算"
        case .mixed: return "GPS 與推估混合"
        case .unknown: return "來源不明"
        }
    }
}

enum CarryPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown, handheld, swingingHand, pocket
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unknown: return "未知／略過"
        case .handheld: return "手持"
        case .swingingHand: return "手持揮臂"
        case .pocket: return "口袋（自行選擇）"
        }
    }
}

struct MeasurementEvidence: Codable, Sendable {
    var version = 1
    var method: MeasurementMethod = .unknown
    var sourceBundle: String?
    var device: String?
    var workoutUUID: String?
    var originSessionID: String?
    var routeSource: String?
    var stepSource: String?
    var distanceSampleSources: [String] = []
    var generatedByThisApp = false
    var stepsAligned = false
    var distanceConfirmed = false
    var gpsMeasuredDistance: Double?
    var stepAssistedDistance: Double?
    var carryPosition: CarryPosition = .unknown
    var loadWeight: Double?
    var pauseIntervals: [DateInterval] = []

    var json: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> Self {
        guard let data = text?.data(using: .utf8), let result = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return result
    }
}

enum QualityGrade: String, Codable, Sendable { case a = "A", b = "B", c = "C", d = "D" }
enum QualityReason: String, Codable, CaseIterable, Sendable {
    case unknownSource, estimatedDistance, assistedDistance, timeMismatch, mixedStepSources
    case missingData, gpsMissing, gpsAccuracy, gpsGap, gpsJump, timeReversed, duplicatePoint
    case strideOutlier, cadenceOutlier, speedOutlier, suspectPersonalDistribution, duplicateWorkout, userExcluded, unsupportedActivity
    var label: String {
        switch self {
        case .unknownSource: return "缺乏可確認的獨立實測來源"
        case .estimatedDistance: return "距離由演算法估算，不作訓練真值"
        case .assistedDistance: return "含 GPS 中斷補距離，無可靠同區段步數"
        case .timeMismatch: return "距離與步數時間窗未確認對齊"
        case .mixedStepSources: return "步數混合裝置來源，無法可靠對齊"
        case .missingData: return "距離、步數或有效時間不足"
        case .gpsMissing: return "沒有足夠原始 GPS 證據"
        case .gpsAccuracy: return "GPS 精度不足或未知"
        case .gpsGap: return "GPS 時間缺口或起終點覆蓋不足"
        case .gpsJump: return "GPS 位移、速度或加速度異常"
        case .timeReversed: return "GPS 時間倒流或重複時間"
        case .duplicatePoint: return "GPS 點重複"
        case .strideOutlier: return "步幅超出該情境合理範圍"
        case .cadenceOutlier: return "步頻與有效時間不合理"
        case .speedOutlier: return "速度與運動類別不符"
        case .suspectPersonalDistribution: return "與既有個人分布差異顯著，待確認"
        case .duplicateWorkout: return "與另一場次高度重疊，只採用一份訓練基礎"
        case .userExcluded: return "使用者排除此筆訓練"
        case .unsupportedActivity: return "非走路、跑步或行軍，不校正步幅"
        }
    }
}

struct GPSObservation: Sendable {
    var latitude: Double
    var longitude: Double
    var date: Date
    var accuracy: Double?
}

struct GPSQuality: Codable, Sendable {
    var coverage: Double?
    var measuredDistance = 0.0
    var reasons: [QualityReason] = []
    var isReliable: Bool { reasons.isEmpty && (coverage ?? 0) >= 0.9 }
}

enum GPSQualityAnalyzer {
    static func distance(_ a: GPSObservation, _ b: GPSObservation) -> Double {
        let radians = Double.pi / 180
        let lat = (b.latitude - a.latitude) * radians
        let lon = (b.longitude - a.longitude) * radians
        let h = pow(sin(lat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
    static func analyze(_ points: [GPSObservation], start: Date, end: Date, pauses: [DateInterval] = []) -> GPSQuality {
        guard points.count > 1, end > start else { return GPSQuality(reasons: [.gpsMissing]) }
        var result = GPSQuality()
        var validTime = 0.0
        var lastSpeed: Double?
        for point in points {
            if !point.latitude.isFinite || !point.longitude.isFinite || abs(point.latitude) > 90 || abs(point.longitude) > 180 {
                result.reasons.append(.gpsJump)
            }
            if point.date < start || point.date > end { result.reasons.append(.timeMismatch) }
            if point.accuracy == nil || !(0...50).contains(point.accuracy ?? -1) { result.reasons.append(.gpsAccuracy) }
        }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dt = b.date.timeIntervalSince(a.date)
            guard dt > 0 else { result.reasons.append(.timeReversed); continue }
            // Pause boundaries are excluded; never bridge them with synthetic GPS distance.
            let interval = DateInterval(start: a.date, end: b.date)
            if pauses.contains(where: { $0.intersection(with: interval)?.duration ?? 0 > 0 }) { lastSpeed = nil; continue }
            let d = distance(a, b)
            if dt > 45 { result.reasons.append(.gpsGap); lastSpeed = nil; continue }
            let speed = d / dt
            if speed > 12 || (lastSpeed.map { abs(speed - $0) / dt > 8 } ?? false) {
                result.reasons.append(.gpsJump); lastSpeed = nil; continue
            }
            if d < 0.01 { result.reasons.append(.duplicatePoint) }
            lastSpeed = speed
            if a.date >= start && b.date <= end { validTime += dt; result.measuredDistance += d }
        }
        let active = max(1, end.timeIntervalSince(start) - pauses.reduce(0) { $0 + ($1.intersection(with: DateInterval(start: start, end: end))?.duration ?? 0) })
        result.coverage = min(1, validTime / active)
        if abs(points[0].date.timeIntervalSince(start)) > 30 || abs(points[points.count - 1].date.timeIntervalSince(end)) > 30 || (result.coverage ?? 0) < 0.9 {
            result.reasons.append(.gpsGap)
        }
        result.reasons = Array(Set(result.reasons)).sorted { $0.rawValue < $1.rawValue }
        return result
    }
}

struct CalibrationDecision: Codable, Sendable {
    var version = 1
    var analyzedAt = Date()
    var grade: QualityGrade
    var eligible: Bool
    var reasons: [QualityReason]
    var gpsCoverage: Double?
    var stride: Double?
    var json: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ text: String?) -> Self? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum CalibrationEligibility {
    static func evaluate(evidence: MeasurementEvidence, distance: Double?, steps: Int?, duration: Double,
                         profile: String, supported: Bool, gps: GPSQuality?, userExcluded: Bool = false) -> CalibrationDecision {
        var reasons: [QualityReason] = []
        if userExcluded { reasons.append(.userExcluded) }
        if !supported { reasons.append(.unsupportedActivity) }
        switch evidence.method {
        case .strideEstimate, .systemEstimate: reasons.append(.estimatedDistance)
        case .mixed: reasons.append(.assistedDistance)
        case .unknown: reasons.append(.unknownSource)
        case .independentGPS, .knownDistance: break
        }
        if !evidence.distanceConfirmed { reasons.append(.unknownSource) }
        if (evidence.stepAssistedDistance ?? 0) > 0 { reasons.append(.assistedDistance) }
        if !evidence.stepsAligned { reasons.append(.timeMismatch) }
        if evidence.stepSource == "mixed" { reasons.append(.mixedStepSources) }
        if evidence.method == .independentGPS {
            if let gps { reasons += gps.reasons } else { reasons.append(.gpsMissing) }
        }
        var stride: Double?
        if let distance, distance.isFinite, distance > 300, let steps, steps > 300, duration.isFinite, duration > 60 {
            stride = distance / Double(steps)
            let range: ClosedRange<Double> = profile == "running" ? 0.4...2.8 : 0.25...1.5
            if !range.contains(stride!) { reasons.append(.strideOutlier) }
            if !(25...260).contains(Double(steps) / duration * 60) { reasons.append(.cadenceOutlier) }
            if distance / duration > (profile == "running" ? 10 : 4) { reasons.append(.speedOutlier) }
            if evidence.method == .independentGPS, let gps, gps.measuredDistance > 0,
               abs(distance - gps.measuredDistance) / distance > 0.15 { reasons.append(.unknownSource) }
        } else { reasons.append(.missingData) }
        reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        let hard: Set<QualityReason> = [.estimatedDistance, .assistedDistance, .gpsJump, .timeReversed, .strideOutlier, .cadenceOutlier, .speedOutlier, .userExcluded, .duplicateWorkout]
        let grade: QualityGrade = reasons.isEmpty ? .a : reasons.contains(where: { hard.contains($0) }) ? .d : reasons.contains(.unknownSource) || reasons.contains(.missingData) || reasons.contains(.unsupportedActivity) ? .c : .b
        return CalibrationDecision(grade: grade, eligible: reasons.isEmpty, reasons: reasons, gpsCoverage: gps?.coverage, stride: stride)
    }
}

/// Stable identity first, conservative full-interval similarity second. Adjacent workouts never merge.
struct WorkoutIdentity: Codable, Sendable {
    var id: String
    var healthUUID: String?
    var originID: String?
    var activity: String
    var start: Date
    var end: Date
    var distance: Double?
    func matches(_ other: Self) -> Bool {
        if id == other.id || (healthUUID != nil && healthUUID == other.healthUUID) || (originID != nil && originID == other.originID) || originID == other.id || other.originID == id { return true }
        guard activity == other.activity, abs(start.timeIntervalSince(other.start)) <= 15,
              abs(end.timeIntervalSince(other.end)) <= 15, end.timeIntervalSince(start) >= 120,
              let distance, let d = other.distance, distance > 0, d > 0 else { return false }
        let overlap = max(0, min(end, other.end).timeIntervalSince(max(start, other.start)))
        return overlap / max(end.timeIntervalSince(start), other.end.timeIntervalSince(other.start)) >= 0.98 && abs(distance - d) / max(distance, d) < 0.02
    }
}
