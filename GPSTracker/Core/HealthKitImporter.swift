import Foundation
import HealthKit
import CoreLocation
import SwiftData
import UIKit

/// 匯入結果
struct ImportResult: Equatable {
    var failure: String?
    var cancelled = false
    var imported = 0
    var skipped = 0
    var withRoute = 0
    var sources: [String: Int] = [:]
    var oldest: Date?
    var newest: Date?
    var finishedAt = Date()

    var isEmpty: Bool { imported == 0 && skipped == 0 }

    var summary: String {
        if let failure { return "匯入未完成：\(failure)（已完成 \(imported) 筆）" }
        if cancelled { return "已安全中斷，保留 \(imported) 筆完整紀錄" }
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
struct HealthImportRoutePoint: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double
    let distanceFromStart: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let course: Double
    let speedAccuracy: Double
    let courseAccuracy: Double
}

struct HealthImportPayload: Sendable {
    let typeRaw: String
    let sportRaw: String?
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistance: Double?
    let averagePace: Double?
    let elevationGain: Double?
    let elevationLoss: Double?
    let stepCount: Int?
    let calories: Double?
    let intensityScore: Double?
    let healthKitUUID: String
    let sourceApp: String
    let detailsJSON: String
    let routePoints: [HealthImportRoutePoint]
}

struct HealthImportKeys: Sendable {
    var uuids: Set<String>
}

/// SwiftData 大量關聯寫入不能塞在主執行緒。
/// HealthKit 匯入可能一次帶進數千個 RoutePoint，舊版會在主執行緒做
/// SwiftData relationship graph traversal，造成 3～7 秒 runloop hang，嚴重時看起來就像閃退。
@ModelActor
actor HealthImportWriter {
    /// 一批不要太大，避免 SwiftData 一次建立幾萬筆 relationship graph；
    /// 也不要太小，否則 save 次數本身會變成主要成本。
    private let routeBatchSize = 500

    private func makeContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    /// App 若在匯入途中被系統終止，下一次匯入先清掉未完成的 staging session。
    /// 舊版本沒有這個欄位（nil）視為已完成，不影響既有資料。
    func existingKeys() throws -> HealthImportKeys {
        let context = makeContext()
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        var uuids = Set<String>()
        var removedIncomplete = false

        for session in sessions {
            if session.healthImportStateRaw == "importing" {
                context.delete(session)
                removedIncomplete = true
            } else if let uuid = session.healthKitUUID {
                uuids.insert(uuid)
            }
        }

        if removedIncomplete {
            try context.save()
        }
        return HealthImportKeys(uuids: uuids)
    }

    @discardableResult
    func insert(_ payload: HealthImportPayload,
                cancellation: ImportCancellation,
                onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Bool {
        // 不用 Thread.isMainThread 當 concurrency 正確性的判斷。
        // Swift actor 的 executor 與 OS thread 不是一對一；真正是否堵住 UI 由整合測試 ticker 驗證。
        onProgress?(0, payload.routePoints.count)

        let uuid = payload.healthKitUUID

        // 先處理同 UUID。完整紀錄直接略過；未完成 staging 紀錄先清掉再重來。
        do {
            let context = makeContext()
            let descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.healthKitUUID == uuid }
            )
            if let existing = try context.fetch(descriptor).first {
                if existing.healthImportStateRaw == "importing" {
                    context.delete(existing)
                    try context.save()
                } else {
                    return false
                }
            }
        }

        try cancellation.check()
        let type = WorkoutType(rawValue: payload.typeRaw) ?? .manualEntry
        let sessionID = UUID()

        // 先只建立 session metadata。route points 之後用新的 ModelContext 分批追加，
        // 讓任何一個 context 都不需要同時追蹤整條幾萬點的軌跡。
        do {
            let context = makeContext()
            let session = WorkoutSession(id: sessionID,
                                         type: type,
                                         startDate: payload.startDate,
                                         endDate: payload.endDate,
                                         duration: payload.duration,
                                         totalDistance: payload.totalDistance,
                                         averagePace: payload.averagePace,
                                         elevationGain: payload.elevationGain,
                                         elevationLoss: payload.elevationLoss,
                                         stepCount: payload.stepCount,
                                         distanceSource: payload.routePoints.count > 1 ? .gps : .pedometer,
                                         routeKey: nil,
                                         title: nil)

            session.calories = payload.calories
            session.intensityScore = payload.intensityScore
            session.sportRaw = payload.sportRaw
            session.healthKitUUID = payload.healthKitUUID
            session.healthKitSynced = true
            session.isImported = true
            session.sourceApp = payload.sourceApp
            session.healthDetailsJSON = payload.detailsJSON
            session.healthImportStateRaw = "importing"
            session.notes = "自 \(payload.sourceApp) 匯入"

            context.insert(session)
            try context.save()
        }

        do {
            var offset = 0
            while offset < payload.routePoints.count {
                try cancellation.check()
                try Task.checkCancellation()

                let upper = min(offset + routeBatchSize, payload.routePoints.count)
                let context = makeContext()
                let id = sessionID
                let descriptor = FetchDescriptor<WorkoutSession>(
                    predicate: #Predicate { $0.id == id }
                )
                guard let session = try context.fetch(descriptor).first else {
                    throw HealthImportWriterError.stagingSessionMissing
                }

                for index in offset..<upper {
                    if index.isMultiple(of: 64) {
                        try cancellation.check()
                    }
                    let point = payload.routePoints[index]
                    let model = RoutePoint(latitude: point.latitude,
                                           longitude: point.longitude,
                                           altitude: point.altitude,
                                           timestamp: point.timestamp,
                                           speed: point.speed,
                                           distanceFromStart: point.distanceFromStart,
                                           horizontalAccuracy: point.horizontalAccuracy,
                                           verticalAccuracy: point.verticalAccuracy,
                                           course: point.course,
                                           rawSpeed: point.speed,
                                           speedAccuracy: point.speedAccuracy,
                                           courseAccuracy: point.courseAccuracy)
                    model.session = session
                    context.insert(model)
                }

                try cancellation.check()
                try context.save()
                offset = upper
                onProgress?(offset, payload.routePoints.count)

                // 主動讓出執行權。資料仍完整保存，只把「一次要 SwiftData 吞多少」
                // 切小，不是抽稀 GPS。
                await Task.yield()
            }

            // 所有 route points 都成功持久化後才標記 complete。
            let context = makeContext()
            let id = sessionID
            let descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.id == id }
            )
            guard let session = try context.fetch(descriptor).first else {
                throw HealthImportWriterError.stagingSessionMissing
            }
            try cancellation.check()
            session.healthImportStateRaw = "complete"
            try context.save()
            return true
        } catch {
            // 取消、磁碟錯誤或任何中途失敗都不能留下「看似完整」的半條軌跡。
            // cascade relationship 會連已寫入的 RoutePoint 一起清除。
            let context = makeContext()
            let id = sessionID
            let descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.id == id }
            )
            if let session = try? context.fetch(descriptor).first {
                context.delete(session)
                try? context.save()
            }
            throw error
        }
    }

    private enum HealthImportWriterError: Error {
        case stagingSessionMissing
    }
}

/// 把健康 App（含其他運動 App 寫入）的歷史訓練，變成本 App 的一般紀錄。
///
/// 匯入的紀錄會標記 `isImported` 與健康 App 的 UUID，
/// 之後不會被重複匯入，也不會再寫回健康 App 造成重複。
@MainActor
final class HealthKitImporter: ObservableObject {
    static let shared = HealthKitImporter()
    @Published private(set) var isImporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var lastResult: ImportResult?
    @Published private(set) var isCancelled = false
    private let health = HealthKitManager.shared
    private var writerTask: Task<HealthImportWriter, Never>?
    private var cancellation = ImportCancellation()

    func configure(container: ModelContainer) {
        guard writerTask == nil else { return }
        // ModelContext and its serial executor must be constructed off MainActor.
        writerTask = Task.detached(priority: .utility) {
            HealthImportWriter(modelContainer: container)
        }
    }

    func cancel() {
        guard isImporting else { return }
        isCancelled = true
        cancellation.cancel()
        statusText = "正在安全中斷…"
    }

    func preview(range: ImportRange, existing: [WorkoutSession]) async -> (total: Int, new: Int) {
        guard health.isReady, let writerTask else { return (0, 0) }
        let workouts = await health.workouts(from: range.startDate)
        let writer = await writerTask.value
        guard let keys = try? await writer.existingKeys() else { return (workouts.count, 0) }
        return (workouts.count, workouts.filter { !keys.uuids.contains($0.uuid.uuidString) }.count)
    }

    @discardableResult
    func importWorkouts(range: ImportRange, existing: [WorkoutSession],
                        includeRoutes: Bool = true) async -> ImportResult {
        await run(from: range.startDate, includeRoutes: includeRoutes)
    }

    @discardableResult
    func importNew(existing: [WorkoutSession]) async -> ImportResult {
        // HealthKit may deliver an old workout or its route days later. A wall-clock
        // start-date watermark silently misses those records; UUID checks are authoritative.
        await run(from: Date(timeIntervalSince1970: 0), includeRoutes: true)
    }

    @discardableResult
    func importNewInBackground() async -> ImportResult { await importNew(existing: []) }

    private func run(from start: Date, includeRoutes: Bool) async -> ImportResult {
        guard health.isReady, let writerTask, !isImporting else { return ImportResult() }
        guard DatabaseHealth.state != .memoryOnly else { return ImportResult(failure: DatabaseHealth.message) }
        isImporting = true
        isCancelled = false
        cancellation = ImportCancellation()
        let token = cancellation
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Health import") { token.cancel() }
        progress = 0
        statusText = "讀取健康訓練…"
        var result = ImportResult()
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            result.finishedAt = Date()
            lastResult = result
            isImporting = false
            isCancelled = false
            statusText = ""
        }
        do {
            let writer = await writerTask.value
            var keys = try await writer.existingKeys()
            let workouts = try await health.importWorkouts(from: start)
            for (index, workout) in workouts.enumerated() {
                try token.check()
                try Task.checkCancellation()
                progress = Double(index) / Double(max(1, workouts.count))
                let uuid = workout.uuid.uuidString
                if keys.uuids.contains(uuid) { result.skipped += 1; continue }
                statusText = "讀取第 \(index + 1) / \(workouts.count) 筆完整軌跡…"
                let locations = includeRoutes ? try await health.completeRoute(of: workout, cancellation: token, onProgress: { count in
                    Task { @MainActor in
                        guard self.isImporting, !self.isCancelled else { return }
                        self.statusText = "讀取第 \(index + 1) 筆：已收到 \(count) 點…"
                    }
                }) : []
                try token.check()
                let type = HealthKitManager.workoutType(for: workout.workoutActivityType, hasRoute: locations.count > 1)
                let sport = SportCatalog.sport(for: workout.workoutActivityType)
                let distance = await health.distance(of: workout)
                let steps = await health.steps(during: workout)
                let energy = await health.energy(of: workout)
                let details = try await health.importDetails(of: workout)
                let weight = AppSettings.shared.bodyWeight
                // No SwiftData models cross executors; CPU-heavy route conversion is detached.
                let payload = await Task.detached(priority: .utility) {
                    Self.makePayload(workout: workout, type: type, sport: sport,
                                     distance: distance, steps: steps, energy: energy,
                                     locations: locations, bodyWeight: weight, detailsJSON: details)
                }.value
                try token.check()
                statusText = "儲存第 \(index + 1) 筆（\(locations.count) 點）…"
                guard try await writer.insert(payload, cancellation: token) else { result.skipped += 1; continue }
                keys.uuids.insert(uuid)
                result.imported += 1
                if !locations.isEmpty { result.withRoute += 1 }
                result.sources[payload.sourceApp, default: 0] += 1
                result.oldest = min(result.oldest ?? workout.startDate, workout.startDate)
                result.newest = max(result.newest ?? workout.startDate, workout.startDate)
            }
            progress = 1
            AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            result.failure = error.localizedDescription
            DiagnosticsLog.shared.log(.error, category: "health-import", "匯入未完成",
                                      detail: ["錯誤": error.localizedDescription])
        }
        return result
    }

    // MARK: 建立紀錄

    nonisolated private static func makePayload(workout: HKWorkout,
                             type: WorkoutType,
                             sport: SportKind?,
                             distance: Double?,
                             steps: Int?,
                             energy: Double?,
                             locations: [CLLocation], bodyWeight: Double, detailsJSON: String) -> HealthImportPayload {
        let duration = workout.duration

        var gain = 0.0
        var loss = 0.0
        var fullRouteDistance = 0.0
        if locations.count > 1 {
            for index in 1..<locations.count {
                let previous = locations[index - 1]
                let current = locations[index]
                let delta = current.altitude - previous.altitude
                if current.verticalAccuracy >= 0, previous.verticalAccuracy >= 0 {
                    if delta > 0.8 { gain += delta } else if delta < -0.8 { loss += -delta }
                }
                let dt = current.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0, dt <= 20 { fullRouteDistance += current.distance(from: previous) }
            }
        }

        let effectiveDistance: Double? = {
            if let distance, distance > 0 { return distance }
            return fullRouteDistance > 0 ? fullRouteDistance : nil
        }()

        let pace: Double? = {
            guard let effectiveDistance, effectiveDistance > 100, duration > 0 else { return nil }
            return duration / (effectiveDistance / 1000)
        }()

        let sourceName = workout.sourceRevision.source.name
        let met = sport?.met ?? type.metValue
        let calories = energy ?? IntensityCalculator.calories(met: met,
                                                               duration: duration,
                                                               bodyWeight: bodyWeight)
        let intensity = IntensityCalculator.score(met: met,
                                                  duration: duration,
                                                  distance: effectiveDistance,
                                                  averagePace: pace,
                                                  elevationGain: locations.count > 1 ? gain : nil)

        let compacted = locations
        var routePoints: [HealthImportRoutePoint] = []
        routePoints.reserveCapacity(compacted.count)

        var accumulated = 0.0
        var previous: CLLocation?
        for location in compacted {
            if let previous {
                let dt = location.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0, dt <= 20 { accumulated += location.distance(from: previous) }
            }
            let reportedSpeed = location.speed

            routePoints.append(HealthImportRoutePoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                timestamp: location.timestamp,
                speed: reportedSpeed,
                distanceFromStart: accumulated,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                course: location.course,
                speedAccuracy: location.speedAccuracy,
                courseAccuracy: location.courseAccuracy
            ))
            previous = location
        }

        return HealthImportPayload(
            typeRaw: type.rawValue,
            sportRaw: sport?.id,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: duration,
            totalDistance: effectiveDistance,
            averagePace: pace,
            elevationGain: locations.count > 1 ? gain : nil,
            elevationLoss: locations.count > 1 ? loss : nil,
            stepCount: steps,
            calories: calories,
            intensityScore: intensity,
            healthKitUUID: workout.uuid.uuidString,
            sourceApp: sourceName,
            detailsJSON: detailsJSON,
            routePoints: routePoints
        )
    }

}
