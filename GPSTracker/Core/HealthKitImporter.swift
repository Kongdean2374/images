import Foundation
import HealthKit
import CoreLocation
import SwiftData

/// 匯入結果
struct ImportResult: Equatable {
    var imported = 0
    var skipped = 0
    var withRoute = 0
    var sources: [String: Int] = [:]
    var oldest: Date?
    var newest: Date?
    var finishedAt = Date()

    var isEmpty: Bool { imported == 0 && skipped == 0 }

    var summary: String {
        if imported == 0 && skipped == 0 { return "沒有找到可匯入的訓練紀錄" }
        var parts = ["匯入 \(imported) 筆"]
        if skipped > 0 { parts.append("略過重複 \(skipped) 筆") }
        if withRoute > 0 { parts.append("含 GPS 軌跡 \(withRoute) 筆") }
        return parts.joined(separator: "、")
    }
}

/// 匯入範圍
enum ImportRange: String, CaseIterable, Identifiable {
    case month3, year1, year3, year5, all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .month3: return "近 3 個月"
        case .year1: return "近 1 年"
        case .year3: return "近 3 年"
        case .year5: return "近 5 年"
        case .all: return "全部"
        }
    }

    var startDate: Date {
        let calendar = Calendar.current
        switch self {
        case .month3: return calendar.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        case .year1: return calendar.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast
        case .year3: return calendar.date(byAdding: .year, value: -3, to: Date()) ?? .distantPast
        case .year5: return calendar.date(byAdding: .year, value: -5, to: Date()) ?? .distantPast
        case .all: return Date(timeIntervalSince1970: 0)
        }
    }
}

/// 把健康 App（含其他運動 App 寫入）的歷史訓練，變成本 App 的一般紀錄。
///
/// 匯入的紀錄會標記 `isImported` 與健康 App 的 UUID，
/// 之後不會被重複匯入，也不會再寫回健康 App 造成重複。
final class HealthKitImporter: ObservableObject {
    static let shared = HealthKitImporter()

    @Published private(set) var isImporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var lastResult: ImportResult?
    @Published private(set) var isCancelled = false

    /// 每寫入這麼多筆就存檔一次，避免一次性佔用太多記憶體
    private let batchSize = 25

    /// 中斷匯入。已經寫入的會保留，下次匯入會自動從沒處理到的繼續。
    @MainActor
    func cancel() {
        guard isImporting else { return }
        isCancelled = true
        statusText = "正在安全中斷…"
    }

    private let health = HealthKitManager.shared
    private var container: ModelContainer?

    @MainActor
    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: 預覽

    /// 先看看這個範圍裡有幾筆、有多少是新的
    @MainActor
    func preview(range: ImportRange, existing: [WorkoutSession]) async -> (total: Int, new: Int) {
        guard health.isReady else { return (0, 0) }
        let workouts = await health.workouts(from: range.startDate)
        let known = Set(existing.compactMap { $0.healthKitUUID })
        let new = workouts.filter { !known.contains($0.uuid.uuidString) }
        return (workouts.count, new.count)
    }

    // MARK: 匯入

    @MainActor
    @discardableResult
    func importWorkouts(range: ImportRange,
                        context: ModelContext,
                        existing: [WorkoutSession],
                        includeRoutes: Bool = true) async -> ImportResult {
        guard health.isReady else {
            statusText = health.availability.displayName
            return ImportResult()
        }

        isImporting = true
        isCancelled = false
        progress = 0
        statusText = "讀取健康 App 的訓練紀錄…"
        defer {
            isImporting = false
            isCancelled = false
            statusText = ""
        }

        let workouts = await health.workouts(from: range.startDate)
        guard !workouts.isEmpty else {
            let empty = ImportResult()
            lastResult = empty
            return empty
        }

        var result = ImportResult()
        // 已匯入過的 UUID，以及「同類型且開始時間相近」的既有紀錄，兩層去重
        let knownUUIDs = Set(existing.compactMap { $0.healthKitUUID })
        let fingerprints = Set(existing.map { fingerprint(type: $0.type, start: $0.startDate) })

        for (index, workout) in workouts.enumerated() {
            if isCancelled {
                try? context.save()
                result.finishedAt = Date()
                lastResult = result
                statusText = ""
                return result
            }
            progress = Double(index) / Double(workouts.count)
            statusText = "處理第 \(index + 1) / \(workouts.count) 筆…"

            if knownUUIDs.contains(workout.uuid.uuidString) {
                result.skipped += 1
                continue
            }

            var locations: [CLLocation] = []
            if includeRoutes {
                locations = await health.route(of: workout)
            }

            let type = HealthKitManager.workoutType(for: workout.workoutActivityType,
                                                    hasRoute: locations.count > 1)
            if fingerprints.contains(fingerprint(type: type, start: workout.startDate)) {
                result.skipped += 1
                continue
            }

            let distance = await health.distance(of: workout)
            let steps = await health.steps(during: workout)
            let energy = await health.energy(of: workout)

            let session = makeSession(workout: workout,
                                      type: type,
                                      distance: distance,
                                      steps: steps,
                                      energy: energy,
                                      locations: locations)
            context.insert(session)

            result.imported += 1
            if locations.count > 1 { result.withRoute += 1 }
            let source = workout.sourceRevision.source.name
            result.sources[source, default: 0] += 1
            if result.oldest == nil || workout.startDate < result.oldest! { result.oldest = workout.startDate }
            if result.newest == nil || workout.startDate > result.newest! { result.newest = workout.startDate }

            // 分批寫入：中途被中斷或 App 被系統收回時，已處理的部分不會流失
            if result.imported % batchSize == 0 {
                try? context.save()
            }
        }

        try? context.save()
        progress = 1
        result.finishedAt = Date()
        lastResult = result
        AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
        return result
    }

    /// 只抓上次匯入之後的新紀錄（App 啟動與背景更新用）
    @MainActor
    @discardableResult
    func importNew(context: ModelContext, existing: [WorkoutSession]) async -> ImportResult {
        let since = AppSettings.shared.lastHealthImportDate
            ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())
            ?? Date()
        guard health.isReady else { return ImportResult() }

        let workouts = await health.workouts(from: since.addingTimeInterval(-3600))
        guard !workouts.isEmpty else {
            AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
            return ImportResult()
        }

        var result = ImportResult()
        let knownUUIDs = Set(existing.compactMap { $0.healthKitUUID })
        let fingerprints = Set(existing.map { fingerprint(type: $0.type, start: $0.startDate) })

        for workout in workouts {
            if knownUUIDs.contains(workout.uuid.uuidString) {
                result.skipped += 1
                continue
            }
            let locations = await health.route(of: workout)
            let type = HealthKitManager.workoutType(for: workout.workoutActivityType,
                                                    hasRoute: locations.count > 1)
            if fingerprints.contains(fingerprint(type: type, start: workout.startDate)) {
                result.skipped += 1
                continue
            }
            let distance = await health.distance(of: workout)
            let steps = await health.steps(during: workout)
            let energy = await health.energy(of: workout)
            context.insert(makeSession(workout: workout,
                                       type: type,
                                       distance: distance,
                                       steps: steps,
                                       energy: energy,
                                       locations: locations))
            result.imported += 1
            if locations.count > 1 { result.withRoute += 1 }
            result.sources[workout.sourceRevision.source.name, default: 0] += 1
        }

        try? context.save()
        AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
        if result.imported > 0 { lastResult = result }
        return result
    }

    /// 背景喚醒用：自己開一個 context
    @MainActor
    @discardableResult
    func importNewInBackground() async -> ImportResult {
        guard let container else { return ImportResult() }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<WorkoutSession>()
        let existing = (try? context.fetch(descriptor)) ?? []
        return await importNew(context: context, existing: existing)
    }

    // MARK: 建立紀錄

    @MainActor
    private func makeSession(workout: HKWorkout,
                             type: WorkoutType,
                             distance: Double?,
                             steps: Int?,
                             energy: Double?,
                             locations: [CLLocation]) -> WorkoutSession {
        let duration = workout.endDate.timeIntervalSince(workout.startDate)
        let pace: Double? = {
            guard let distance, distance > 100, duration > 0 else { return nil }
            return duration / (distance / 1000)
        }()

        var gain = 0.0
        var loss = 0.0
        if locations.count > 1 {
            for index in 1..<locations.count {
                let delta = locations[index].altitude - locations[index - 1].altitude
                if delta > 0.8 { gain += delta } else if delta < -0.8 { loss += -delta }
            }
        }

        let sourceName = workout.sourceRevision.source.name
        let session = WorkoutSession(type: type,
                                     startDate: workout.startDate,
                                     endDate: workout.endDate,
                                     duration: duration,
                                     totalDistance: distance,
                                     averagePace: pace,
                                     elevationGain: locations.count > 1 ? gain : nil,
                                     elevationLoss: locations.count > 1 ? loss : nil,
                                     stepCount: steps,
                                     distanceSource: locations.count > 1 ? .gps : .pedometer,
                                     routeKey: nil,
                                     title: nil)
        session.calories = energy ?? IntensityCalculator.calories(type: type,
                                                                  duration: duration,
                                                                  bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: type,
                                                           duration: duration,
                                                           distance: distance,
                                                           averagePace: pace,
                                                           elevationGain: locations.count > 1 ? gain : nil)
        session.healthKitUUID = workout.uuid.uuidString
        session.healthKitSynced = true   // 來自健康 App，不需要再寫回去
        session.isImported = true
        session.sourceApp = sourceName
        session.notes = "自 \(sourceName) 匯入"

        if locations.count > 1 {
            var accumulated = 0.0
            var previous: CLLocation?
            var points: [RoutePoint] = []
            for location in locations {
                if let previous {
                    accumulated += location.distance(from: previous)
                }
                points.append(RoutePoint(latitude: location.coordinate.latitude,
                                         longitude: location.coordinate.longitude,
                                         altitude: location.altitude,
                                         timestamp: location.timestamp,
                                         speed: max(0, location.speed),
                                         distanceFromStart: accumulated))
                previous = location
            }
            session.routePoints = points
            if distance == nil, accumulated > 0 {
                session.totalDistance = accumulated
            }
        }
        return session
    }

    private func fingerprint(type: WorkoutType, start: Date) -> String {
        // 以分鐘為單位比對，避免同一次運動被不同來源重複記錄
        "\(type.rawValue)-\(Int(start.timeIntervalSince1970 / 60))"
    }
}
