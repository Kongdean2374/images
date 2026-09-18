import Foundation
import SwiftData

// MARK: - Workout type

enum WorkoutType: String, Codable, CaseIterable, Identifiable, Hashable {
    case gpsRun
    case gpsHike
    case walk
    case run
    case treadmill
    case lapCounter
    case indoorInterval
    case indoorReps
    case plank
    case stairs
    case shuttleRun
    case ruck
    /// 以 GPS 記錄的其他運動（自行車、滑雪、獨木舟…）
    case gpsActivity
    /// 以計時為主的其他運動（球類、瑜伽、重訓…）
    case timedActivity
    case fitnessTest
    case manualEntry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpsRun: return "GPS 路跑"
        case .gpsHike: return "GPS 健行"
        case .walk: return "走路"
        case .run: return "跑步"
        case .treadmill: return "跑步機"
        case .lapCounter: return "營區計圈"
        case .indoorInterval: return "室內間歇"
        case .indoorReps: return "原地運動"
        case .plank: return "棒式撐體"
        case .stairs: return "爬樓梯"
        case .shuttleRun: return "折返跑"
        case .ruck: return "負重行軍"
        case .gpsActivity: return "戶外運動"
        case .timedActivity: return "其他運動"
        case .fitnessTest: return "體能測驗"
        case .manualEntry: return "手動輸入"
        }
    }

    var shortName: String {
        switch self {
        case .gpsRun: return "路跑"
        case .gpsHike: return "健行"
        case .walk: return "走路"
        case .run: return "跑步"
        case .treadmill: return "跑步機"
        case .lapCounter: return "計圈"
        case .indoorInterval: return "間歇"
        case .indoorReps: return "原地"
        case .plank: return "棒式"
        case .stairs: return "樓梯"
        case .shuttleRun: return "折返"
        case .ruck: return "負重"
        case .gpsActivity: return "戶外"
        case .timedActivity: return "運動"
        case .fitnessTest: return "體測"
        case .manualEntry: return "手動"
        }
    }

    var systemImage: String {
        switch self {
        case .gpsRun: return "figure.run"
        case .gpsHike: return "figure.hiking"
        case .walk: return "figure.walk"
        case .run: return "figure.run.circle"
        case .treadmill: return "figure.run.treadmill"
        case .lapCounter: return "arrow.triangle.capsulepath"
        case .indoorInterval: return "timer"
        case .indoorReps: return "figure.jumprope"
        case .plank: return "figure.core.training"
        case .stairs: return "figure.stair.stepper"
        case .shuttleRun: return "arrow.left.arrow.right"
        case .ruck: return "backpack.fill"
        case .gpsActivity: return "map.circle.fill"
        case .timedActivity: return "figure.mixed.cardio"
        case .fitnessTest: return "medal.fill"
        case .manualEntry: return "square.and.pencil"
        }
    }

    /// 是否需要定位權限；無定位模組（模組 B）全部為 false。
    var requiresLocation: Bool {
        self == .gpsRun || self == .gpsHike || self == .gpsActivity
    }

    /// 需要搭配「運動項目」才知道是哪一種
    var usesSportKind: Bool {
        self == .gpsActivity || self == .timedActivity
    }

    /// 以計步器為主的無定位模式
    var isStepBased: Bool {
        self == .walk || self == .run || self == .treadmill || self == .stairs || self == .ruck
    }

    /// 步幅校正時歸類為走路或跑步
    var strideProfile: StrideProfile {
        switch self {
        case .walk, .gpsHike: return .walking
        default: return .running
        }
    }

    /// MET 值，用於熱量與強度估算。
    var metValue: Double {
        switch self {
        case .gpsRun: return 9.8
        case .gpsHike: return 6.0
        case .walk: return 3.5
        case .run: return 9.0
        case .treadmill: return 8.3
        case .lapCounter: return 8.3
        case .indoorInterval: return 8.0
        case .indoorReps: return 7.0
        case .plank: return 4.0
        case .stairs: return 8.8
        case .shuttleRun: return 9.5
        case .ruck: return 6.5
        case .gpsActivity: return 7.5
        case .timedActivity: return 6.0
        case .fitnessTest: return 8.5
        case .manualEntry: return 7.0
        }
    }
}

enum StrideProfile: String, Codable {
    case walking, running
}

/// 距離是怎麼算出來的，讓使用者知道數字可信度
enum DistanceSource: String, Codable {
    case gps
    case pedometer
    case stride
    case lap
    case manual

    var displayName: String {
        switch self {
        case .gps: return "GPS 軌跡"
        case .pedometer: return "系統計步估算"
        case .stride: return "個人步幅換算"
        case .lap: return "圈數換算"
        case .manual: return "手動輸入"
        }
    }
}

// MARK: - Session

@Model
final class WorkoutSession {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    /// 公尺。無定位模式可為推估值或 nil。
    var totalDistance: Double?
    /// 秒 / 公里
    var averagePace: Double?
    var elevationGain: Double?
    var elevationLoss: Double?
    var stepCount: Int?
    var cadence: Double?
    var repCount: Int?
    var calories: Double?
    var intensityScore: Double?
    var weatherNote: String?
    var temperature: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?
    /// 本次使用的步幅（公尺），供回溯檢視
    var strideLength: Double?
    /// 動作辨識分段：走路 / 跑步各佔多少秒
    var walkingSeconds: Double?
    var runningSeconds: Double?
    /// 是否已寫入健康 App
    var healthKitSynced: Bool = false
    /// 對應的健康 App 訓練 UUID（避免重複匯入／重複寫入）
    var healthKitUUID: String?
    /// 這筆紀錄是從健康 App 匯入的
    var isImported: Bool = false
    /// 原始來源 App 名稱（例如 Apple Watch、Nike Run Club）
    var sourceApp: String?
    /// 距離來源：gps / pedometer / stride / manual
    var distanceSourceRaw: String?
    /// 自覺強度 RPE 1-10（運動後自行評分）
    var rpe: Int?
    /// 運動結束當下的心率（手動量測輸入）
    var heartRateAfter: Int?
    /// 結束後一分鐘的心率，用來看恢復能力
    var heartRateOneMinute: Int?
    /// 負重行軍的負重（公斤）
    var loadWeight: Double?
    /// 具體的運動項目（來自運動目錄），例如籃球、瑜伽、自行車
    var sportRaw: String?
    /// 自訂計次（球類局數、重訓組數等）
    var setCount: Int?
    /// 暫停／繼續的時間點（成對出現），用來讓健康 App 算出正確的「體能訓練時間」
    var pauseLog: [Date]?
    /// 同路線比較用的識別名稱（GPS 路線名或圈數設定）。
    var routeKey: String?
    var title: String?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.session)
    var routePoints: [RoutePoint]

    @Relationship(deleteRule: .cascade, inverse: \LapRecord.session)
    var laps: [LapRecord]

    init(id: UUID = UUID(),
         type: WorkoutType,
         startDate: Date,
         endDate: Date,
         duration: TimeInterval,
         totalDistance: Double? = nil,
         averagePace: Double? = nil,
         elevationGain: Double? = nil,
         elevationLoss: Double? = nil,
         stepCount: Int? = nil,
         cadence: Double? = nil,
         repCount: Int? = nil,
         calories: Double? = nil,
         intensityScore: Double? = nil,
         weatherNote: String? = nil,
         temperature: Double? = nil,
         floorsAscended: Int? = nil,
         floorsDescended: Int? = nil,
         strideLength: Double? = nil,
         walkingSeconds: Double? = nil,
         runningSeconds: Double? = nil,
         distanceSource: DistanceSource? = nil,
         routeKey: String? = nil,
         title: String? = nil,
         notes: String? = nil) {
        self.id = id
        self.typeRaw = type.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.totalDistance = totalDistance
        self.averagePace = averagePace
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.stepCount = stepCount
        self.cadence = cadence
        self.repCount = repCount
        self.calories = calories
        self.intensityScore = intensityScore
        self.weatherNote = weatherNote
        self.temperature = temperature
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.strideLength = strideLength
        self.walkingSeconds = walkingSeconds
        self.runningSeconds = runningSeconds
        self.healthKitSynced = false
        self.healthKitUUID = nil
        self.isImported = false
        self.sourceApp = nil
        self.distanceSourceRaw = distanceSource?.rawValue
        self.routeKey = routeKey
        self.title = title
        self.notes = notes
        self.routePoints = []
        self.laps = []
    }

    var type: WorkoutType {
        get { WorkoutType(rawValue: typeRaw) ?? .manualEntry }
        set { typeRaw = newValue.rawValue }
    }

    /// 一分鐘心率下降幅度，越大代表恢復越好
    /// 對應的運動項目
    var sport: SportKind? {
        get { SportCatalog.find(sportRaw) }
        set { sportRaw = newValue?.id }
    }

    /// 熱量與強度估算用的 MET：有指定項目就用項目的
    var effectiveMET: Double {
        sport?.met ?? type.metValue
    }

    /// 這種運動在健康 App 裡是以「速度」而不是「配速」呈現（單車、滑雪、划船之類）
    var prefersSpeed: Bool {
        guard let sport else { return false }
        switch SportCatalog.healthKitType(for: sport) {
        case .cycling, .handCycling, .downhillSkiing, .crossCountrySkiing,
             .snowboarding, .rowing, .paddleSports, .sailing, .skatingSports:
            return true
        default:
            return false
        }
    }

    /// 平均速度（公尺/秒）
    var averageSpeed: Double? {
        guard let distance = totalDistance, distance > 0, duration > 0 else { return nil }
        return distance / duration
    }

    /// 這種運動用計步器數出來的步數才有意義（騎車、游泳的步數只是雜訊）
    var stepsAreMeaningful: Bool {
        guard let sport else { return true }
        switch SportCatalog.healthKitType(for: sport) {
        case .walking, .running, .hiking: return true
        default: return false
        }
    }

    /// 顯示用的圖示
    var displayIcon: String {
        sport?.icon ?? type.systemImage
    }

    var heartRateRecovery: Int? {
        guard let after = heartRateAfter, let oneMinute = heartRateOneMinute else { return nil }
        return max(0, after - oneMinute)
    }

    var distanceSource: DistanceSource? {
        get { distanceSourceRaw.flatMap { DistanceSource(rawValue: $0) } }
        set { distanceSourceRaw = newValue?.rawValue }
    }

    var hasRoute: Bool { !routePoints.isEmpty }

    var sortedPoints: [RoutePoint] {
        routePoints.sorted { $0.timestamp < $1.timestamp }
    }

    var sortedLaps: [LapRecord] {
        laps.sorted { $0.lapNumber < $1.lapNumber }
    }

    var distanceKM: Double {
        (totalDistance ?? 0) / 1000.0
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let sport { return sport.name }
        return type.displayName
    }

    /// 資料是自己記錄的還是從健康 App 匯入的
    var originLabel: String {
        if isImported {
            if let sourceApp, !sourceApp.isEmpty { return sourceApp }
            return "健康 App"
        }
        return "本機記錄"
    }
}

// MARK: - Route point

@Model
final class RoutePoint {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date
    /// 平滑後的瞬時速度（公尺/秒）
    var speed: Double
    /// 自起點累積距離（公尺）
    var distanceFromStart: Double
    var session: WorkoutSession?

    init(latitude: Double,
         longitude: Double,
         altitude: Double,
         timestamp: Date,
         speed: Double = 0,
         distanceFromStart: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.speed = speed
        self.distanceFromStart = distanceFromStart
    }

    /// 秒 / 公里，速度為 0 時回傳 nil
    var pace: Double? {
        speed > 0.2 ? 1000.0 / speed : nil
    }
}

// MARK: - Lap

@Model
final class LapRecord {
    var lapNumber: Int
    var lapDuration: TimeInterval
    /// 使用者輸入的已知單圈距離（公尺）
    var distanceOverride: Double?
    var timestamp: Date
    var session: WorkoutSession?

    init(lapNumber: Int,
         lapDuration: TimeInterval,
         distanceOverride: Double? = nil,
         timestamp: Date = Date()) {
        self.lapNumber = lapNumber
        self.lapDuration = lapDuration
        self.distanceOverride = distanceOverride
        self.timestamp = timestamp
    }

    /// 該圈配速（秒 / 公里）
    var pace: Double? {
        guard let d = distanceOverride, d > 0 else { return nil }
        return lapDuration / (d / 1000.0)
    }
}

// MARK: - Goal

enum GoalPeriod: String, Codable, CaseIterable, Identifiable {
    case weekly, monthly
    var id: String { rawValue }
    var displayName: String { self == .weekly ? "每週" : "每月" }
}

enum GoalMetric: String, Codable, CaseIterable, Identifiable {
    case distance, count, duration
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .distance: return "里程"
        case .count: return "次數"
        case .duration: return "時間"
        }
    }
    var unit: String {
        switch self {
        case .distance: return "公里"
        case .count: return "次"
        case .duration: return "分鐘"
        }
    }
}

@Model
final class WorkoutGoal {
    @Attribute(.unique) var id: UUID
    var periodRaw: String
    var metricRaw: String
    var target: Double
    var createdAt: Date

    init(id: UUID = UUID(),
         period: GoalPeriod,
         metric: GoalMetric,
         target: Double,
         createdAt: Date = Date()) {
        self.id = id
        self.periodRaw = period.rawValue
        self.metricRaw = metric.rawValue
        self.target = target
        self.createdAt = createdAt
    }

    var period: GoalPeriod {
        get { GoalPeriod(rawValue: periodRaw) ?? .weekly }
        set { periodRaw = newValue.rawValue }
    }

    var metric: GoalMetric {
        get { GoalMetric(rawValue: metricRaw) ?? .distance }
        set { metricRaw = newValue.rawValue }
    }
}
