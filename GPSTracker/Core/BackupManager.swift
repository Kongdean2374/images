import Foundation
import SwiftData

// MARK: - 備份格式

struct RoutePointBackup: Codable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date
    var speed: Double
    var distanceFromStart: Double
}

struct LapBackup: Codable {
    var lapNumber: Int
    var lapDuration: TimeInterval
    var distanceOverride: Double?
    var timestamp: Date
}

struct SessionBackup: Codable {
    var id: UUID
    var type: String
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var totalDistance: Double?
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
    var strideLength: Double?
    var walkingSeconds: Double?
    var runningSeconds: Double?
    var healthKitSynced: Bool
    var healthKitUUID: String?
    var isImported: Bool
    var sourceApp: String?
    var distanceSource: String?
    var rpe: Int?
    var routeKey: String?
    var title: String?
    var notes: String?
    var routePoints: [RoutePointBackup]
    var laps: [LapBackup]
}

struct GoalBackup: Codable {
    var id: UUID
    var period: String
    var metric: String
    var target: Double
    var createdAt: Date
}

struct SettingsBackup: Codable {
    var unit: String
    var bodyWeight: Double
    var lapDistance: Double
    var voiceCues: Bool
    var hapticCues: Bool
    var autoPause: Bool
    var mapPitch: Double
    var preferDarkMode: Bool
    var dailyStepGoal: Int
    var dailyDistanceGoal: Double
}

struct BackupPayload: Codable {
    var formatVersion: Int
    var appVersion: String
    var exportedAt: Date
    var includesRoutes: Bool
    var sessions: [SessionBackup]
    var goals: [GoalBackup]
    var settings: SettingsBackup
    var strideWalking: StrideState?
    var strideRunning: StrideState?
    var exercises: [ExerciseItem]
    var intervalPlans: [IntervalPlan]
    var fitnessStandards: FitnessStandards

    var routePointCount: Int {
        sessions.reduce(0) { $0 + $1.routePoints.count }
    }

    var dateRange: (first: Date, last: Date)? {
        guard let first = sessions.map({ $0.startDate }).min(),
              let last = sessions.map({ $0.startDate }).max() else { return nil }
        return (first, last)
    }
}

// MARK: - 備份與還原

enum RestoreMode: String, CaseIterable, Identifiable {
    case merge, replace

    var id: String { rawValue }

    var displayName: String {
        self == .merge ? "合併（只補沒有的）" : "取代（清空後還原）"
    }

    var detail: String {
        self == .merge
            ? "保留現有紀錄，只加入備份中沒有的部分。最安全。"
            : "刪除裝置上所有現有紀錄，完全還原成備份當下的狀態。"
    }
}

struct RestoreResult {
    var added = 0
    var skipped = 0
    var removed = 0
    var goalsAdded = 0
    var settingsRestored = false

    var summary: String {
        var parts = ["還原 \(added) 筆紀錄"]
        if skipped > 0 { parts.append("略過重複 \(skipped) 筆") }
        if removed > 0 { parts.append("移除舊資料 \(removed) 筆") }
        return parts.joined(separator: "、")
    }
}

final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var isWorking = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""

    static let currentFormatVersion = 1

    // MARK: 匯出

    @MainActor
    func makePayload(sessions: [WorkoutSession],
                     goals: [WorkoutGoal],
                     includeRoutes: Bool) -> BackupPayload {
        let settings = AppSettings.shared
        return BackupPayload(
            formatVersion: Self.currentFormatVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            exportedAt: Date(),
            includesRoutes: includeRoutes,
            sessions: sessions.map { session in
                SessionBackup(id: session.id,
                              type: session.typeRaw,
                              startDate: session.startDate,
                              endDate: session.endDate,
                              duration: session.duration,
                              totalDistance: session.totalDistance,
                              averagePace: session.averagePace,
                              elevationGain: session.elevationGain,
                              elevationLoss: session.elevationLoss,
                              stepCount: session.stepCount,
                              cadence: session.cadence,
                              repCount: session.repCount,
                              calories: session.calories,
                              intensityScore: session.intensityScore,
                              weatherNote: session.weatherNote,
                              temperature: session.temperature,
                              floorsAscended: session.floorsAscended,
                              floorsDescended: session.floorsDescended,
                              strideLength: session.strideLength,
                              walkingSeconds: session.walkingSeconds,
                              runningSeconds: session.runningSeconds,
                              healthKitSynced: session.healthKitSynced,
                              healthKitUUID: session.healthKitUUID,
                              isImported: session.isImported,
                              sourceApp: session.sourceApp,
                              distanceSource: session.distanceSourceRaw,
                              rpe: session.rpe,
                              routeKey: session.routeKey,
                              title: session.title,
                              notes: session.notes,
                              routePoints: includeRoutes
                                ? session.sortedPoints.map {
                                    RoutePointBackup(latitude: $0.latitude,
                                                     longitude: $0.longitude,
                                                     altitude: $0.altitude,
                                                     timestamp: $0.timestamp,
                                                     speed: $0.speed,
                                                     distanceFromStart: $0.distanceFromStart)
                                  }
                                : [],
                              laps: session.sortedLaps.map {
                                  LapBackup(lapNumber: $0.lapNumber,
                                            lapDuration: $0.lapDuration,
                                            distanceOverride: $0.distanceOverride,
                                            timestamp: $0.timestamp)
                              })
            },
            goals: goals.map {
                GoalBackup(id: $0.id, period: $0.periodRaw, metric: $0.metricRaw,
                           target: $0.target, createdAt: $0.createdAt)
            },
            settings: SettingsBackup(unit: settings.unitRaw,
                                     bodyWeight: settings.bodyWeight,
                                     lapDistance: settings.lapDistance,
                                     voiceCues: settings.voiceCues,
                                     hapticCues: settings.hapticCues,
                                     autoPause: settings.autoPause,
                                     mapPitch: settings.mapPitch,
                                     preferDarkMode: settings.preferDarkMode,
                                     dailyStepGoal: settings.dailyStepGoal,
                                     dailyDistanceGoal: settings.dailyDistanceGoal),
            strideWalking: StrideCalibration.state(.walking),
            strideRunning: StrideCalibration.state(.running),
            exercises: ExerciseLibrary.shared.items,
            intervalPlans: IntervalPlanStore.shared.plans,
            fitnessStandards: FitnessStandardsStore.load()
        )
    }

    @MainActor
    func exportBackup(sessions: [WorkoutSession],
                      goals: [WorkoutGoal],
                      includeRoutes: Bool) -> URL? {
        isWorking = true
        statusText = "整理資料…"
        defer {
            isWorking = false
            statusText = ""
        }
        let payload = makePayload(sessions: sessions, goals: goals, includeRoutes: includeRoutes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return nil }
        let name = "gpstracker-backup-\(DataExporter.stamp()).json"
        return DataExporter.write(data, filename: name)
    }

    // MARK: 讀取備份檔

    func readPayload(from url: URL) -> BackupPayload? {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupPayload.self, from: data)
    }

    // MARK: 還原

    @MainActor
    func restore(payload: BackupPayload,
                 mode: RestoreMode,
                 restoreSettings: Bool,
                 context: ModelContext,
                 existing: [WorkoutSession],
                 existingGoals: [WorkoutGoal]) -> RestoreResult {
        isWorking = true
        progress = 0
        defer {
            isWorking = false
            statusText = ""
            progress = 0
        }

        var result = RestoreResult()

        if mode == .replace {
            statusText = "清除現有資料…"
            for session in existing {
                context.delete(session)
                result.removed += 1
            }
            for goal in existingGoals {
                context.delete(goal)
            }
            try? context.save()
        }

        let knownIDs = mode == .replace ? Set<UUID>() : Set(existing.map { $0.id })
        let knownHealthUUIDs = mode == .replace
            ? Set<String>()
            : Set(existing.compactMap { $0.healthKitUUID })

        for (index, backup) in payload.sessions.enumerated() {
            statusText = "還原第 \(index + 1) / \(payload.sessions.count) 筆…"
            progress = Double(index) / Double(max(1, payload.sessions.count))

            if knownIDs.contains(backup.id) {
                result.skipped += 1
                continue
            }
            if let uuid = backup.healthKitUUID, knownHealthUUIDs.contains(uuid) {
                result.skipped += 1
                continue
            }

            let session = WorkoutSession(id: backup.id,
                                         type: WorkoutType(rawValue: backup.type) ?? .manualEntry,
                                         startDate: backup.startDate,
                                         endDate: backup.endDate,
                                         duration: backup.duration,
                                         totalDistance: backup.totalDistance,
                                         averagePace: backup.averagePace,
                                         elevationGain: backup.elevationGain,
                                         elevationLoss: backup.elevationLoss,
                                         stepCount: backup.stepCount,
                                         cadence: backup.cadence,
                                         repCount: backup.repCount,
                                         weatherNote: backup.weatherNote,
                                         temperature: backup.temperature,
                                         floorsAscended: backup.floorsAscended,
                                         floorsDescended: backup.floorsDescended,
                                         strideLength: backup.strideLength,
                                         walkingSeconds: backup.walkingSeconds,
                                         runningSeconds: backup.runningSeconds,
                                         routeKey: backup.routeKey,
                                         title: backup.title,
                                         notes: backup.notes)
            session.calories = backup.calories
            session.intensityScore = backup.intensityScore
            session.healthKitSynced = backup.healthKitSynced
            session.healthKitUUID = backup.healthKitUUID
            session.isImported = backup.isImported
            session.sourceApp = backup.sourceApp
            session.distanceSourceRaw = backup.distanceSource
            session.rpe = backup.rpe
            session.routePoints = backup.routePoints.map {
                RoutePoint(latitude: $0.latitude,
                           longitude: $0.longitude,
                           altitude: $0.altitude,
                           timestamp: $0.timestamp,
                           speed: $0.speed,
                           distanceFromStart: $0.distanceFromStart)
            }
            session.laps = backup.laps.map {
                LapRecord(lapNumber: $0.lapNumber,
                          lapDuration: $0.lapDuration,
                          distanceOverride: $0.distanceOverride,
                          timestamp: $0.timestamp)
            }
            context.insert(session)
            result.added += 1

            if result.added % 40 == 0 {
                try? context.save()
            }
        }

        let goalIDs = Set(existingGoals.map { $0.id })
        for goal in payload.goals where mode == .replace || !goalIDs.contains(goal.id) {
            context.insert(WorkoutGoal(id: goal.id,
                                       period: GoalPeriod(rawValue: goal.period) ?? .weekly,
                                       metric: GoalMetric(rawValue: goal.metric) ?? .distance,
                                       target: goal.target,
                                       createdAt: goal.createdAt))
            result.goalsAdded += 1
        }

        try? context.save()

        if restoreSettings {
            let settings = AppSettings.shared
            settings.unitRaw = payload.settings.unit
            settings.bodyWeight = payload.settings.bodyWeight
            settings.lapDistance = payload.settings.lapDistance
            settings.voiceCues = payload.settings.voiceCues
            settings.hapticCues = payload.settings.hapticCues
            settings.autoPause = payload.settings.autoPause
            settings.mapPitch = payload.settings.mapPitch
            settings.preferDarkMode = payload.settings.preferDarkMode
            settings.dailyStepGoal = payload.settings.dailyStepGoal
            settings.dailyDistanceGoal = payload.settings.dailyDistanceGoal

            if let walking = payload.strideWalking { StrideCalibration.restore(walking, profile: .walking) }
            if let running = payload.strideRunning { StrideCalibration.restore(running, profile: .running) }
            FitnessStandardsStore.save(payload.fitnessStandards)
            result.settingsRestored = true
        }

        progress = 1
        return result
    }
}
