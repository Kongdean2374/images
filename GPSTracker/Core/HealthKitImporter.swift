import Foundation
import HealthKit
import CoreLocation
import SwiftData

/// 匯入結果
struct ImportResult: Equatable {
    var scanned = 0
    var cancelled = false
    var error: String?
    var imported = 0
    var skipped = 0
    var withRoute = 0
    var sources: [String: Int] = [:]
    var oldest: Date?
    var newest: Date?
    var finishedAt = Date()

    var isEmpty: Bool { imported == 0 && skipped == 0 }

    var summary: String {
        if let error { return "匯入未完成：" + error }
        if cancelled { return "已取消，保留已新增 \(imported) 筆紀錄" }
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
private struct HealthImportRoutePoint: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double
    let accuracy: Double
    let distanceFromStart: Double
}

private struct HealthImportPayload: Sendable {
    var identity: WorkoutIdentity {
        WorkoutIdentity(id: evidence.originSessionID ?? healthKitUUID, healthUUID: healthKitUUID,
                        originID: evidence.originSessionID,
                        activity: Self.activityKey(typeRaw: typeRaw, sportRaw: sportRaw),
                        start: startDate, end: endDate, distance: totalDistance)
    }
    private static func activityKey(typeRaw: String, sportRaw: String?) -> String {
        let type = WorkoutType(rawValue: typeRaw) ?? .manualEntry
        return type.isStepBased || type == .gpsRun || type == .gpsHike ? type.strideProfile.rawValue : sportRaw ?? typeRaw
    }
    let evidence: MeasurementEvidence
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
    let routePoints: [HealthImportRoutePoint]
}

private struct HealthImportKeys: Sendable {
    var uuids: Set<String>
    var identities: [WorkoutIdentity]
}

/// SwiftData 大量關聯寫入不能塞在主執行緒。
/// HealthKit 匯入可能一次帶進數千個 RoutePoint，舊版會在主執行緒做
/// SwiftData relationship graph traversal，造成 3～7 秒 runloop hang，嚴重時看起來就像閃退。
@ModelActor
private actor HealthImportWriter {
    func existingKeys() throws -> HealthImportKeys {
        let sessions = try modelContext.fetch(FetchDescriptor<WorkoutSession>())
        return HealthImportKeys(
            uuids: Set(sessions.compactMap { $0.healthKitUUID }),
            identities: sessions.map { CalibrationSessionAnalyzer.identity($0) }
        )
    }

    func insert(_ payload: HealthImportPayload) throws -> Bool {
        modelContext.autosaveEnabled = false
        let keys = try existingKeys()
        if keys.uuids.contains(payload.healthKitUUID) || keys.identities.contains(where: { $0.matches(payload.identity) }) { return false }
        let type = WorkoutType(rawValue: payload.typeRaw) ?? .manualEntry
        let session = WorkoutSession(type: type,
                                     startDate: payload.startDate,
                                     endDate: payload.endDate,
                                     duration: payload.duration,
                                     totalDistance: payload.totalDistance,
                                     averagePace: payload.averagePace,
                                     elevationGain: payload.elevationGain,
                                     elevationLoss: payload.elevationLoss,
                                     stepCount: payload.stepCount,
                                     distanceSource: payload.evidence.method == .independentGPS ? .gps : payload.evidence.method == .mixed ? .mixed : payload.evidence.method == .strideEstimate ? .stride : payload.evidence.method == .systemEstimate ? .pedometer : .unknown,
                                     routeKey: nil,
                                     title: nil)

        session.calories = payload.calories
        session.intensityScore = payload.intensityScore
        session.sportRaw = payload.sportRaw
        session.healthKitUUID = payload.healthKitUUID
        session.healthKitSynced = true
        session.isImported = true
        session.sourceApp = payload.sourceApp
        session.notes = "自 \(payload.sourceApp) 匯入"
        session.evidence = payload.evidence
        session.loadWeight = payload.evidence.loadWeight
        session.carryPositionRaw = payload.evidence.carryPosition.rawValue
        session.pauseLog = payload.evidence.pauseIntervals.flatMap { [$0.start, $0.end] }

        if !payload.routePoints.isEmpty {
            session.routePoints = payload.routePoints.map { point in
                RoutePoint(latitude: point.latitude,
                           longitude: point.longitude,
                           altitude: point.altitude,
                           timestamp: point.timestamp,
                           speed: point.speed,
                           distanceFromStart: point.distanceFromStart,
                           horizontalAccuracy: point.accuracy)
            }
        }

        modelContext.insert(session)
        do { try modelContext.save(); return true }
        catch { modelContext.rollback(); throw error }
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

    private let health = HealthKitManager.shared
    private var writer: HealthImportWriter?

    /// 中斷匯入。每一筆完成後就會立即存檔，已完成的紀錄不會遺失。
    @MainActor
    func cancel() {
        guard isImporting else { return }
        isCancelled = true
        statusText = "正在安全中斷…"
    }

    @MainActor
    func configure(container: ModelContainer) async {
        guard !DatabaseHealth.needsAttention else { return }
        writer = await Task.detached { HealthImportWriter(modelContainer: container) }.value
    }

    // MARK: 預覽

    /// 先看看這個範圍裡有幾筆、有多少是新的
    @MainActor
    func preview(range: ImportRange, existing: [WorkoutSession]) async -> (total: Int, new: Int) {
        guard health.isReady else { return (0, 0) }
        let workouts = await health.workouts(from: range.startDate)

        let known: Set<String>
        if let writer, let keys = try? await writer.existingKeys() {
            known = keys.uuids
        } else {
            known = Set(existing.compactMap { $0.healthKitUUID })
        }

        let new = workouts.filter { !known.contains($0.uuid.uuidString) }
        return (workouts.count, new.count)
    }

    // MARK: 匯入

    @MainActor
    @discardableResult
    func importWorkouts(range: ImportRange, existing: [WorkoutSession], includeRoutes: Bool = true) async -> ImportResult {
        await performImport(from: range.startDate, existing: existing, includeRoutes: includeRoutes)
    }

    @MainActor
    @discardableResult
    func importNew(existing: [WorkoutSession]) async -> ImportResult {
        let since = AppSettings.shared.lastHealthImportDate ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return await performImport(from: since.addingTimeInterval(-3600), existing: existing, includeRoutes: true)
    }

    @MainActor
    private func performImport(from start: Date, existing: [WorkoutSession], includeRoutes: Bool) async -> ImportResult {
        guard health.isReady, let writer, !isImporting else { return ImportResult(error: "健康權限、資料庫未就緒或已有匯入進行中") }
        isImporting = true; isCancelled = false; progress = 0
        defer { isImporting = false; statusText = "" }
        statusText = "讀取健康 App 歷史…"
        let workouts: [HKWorkout]
        do { workouts = try await health.completeWorkouts(from: start) }
        catch {
            let result = ImportResult(error: "健康資料讀取失敗，未推進匯入進度：" + error.localizedDescription)
            lastResult = result
            return result
        }
        var result = ImportResult()
        do {
            var keys = try await writer.existingKeys()
            for (index, workout) in workouts.enumerated() {
                if isCancelled || Task.isCancelled { result.cancelled = true; break }
                statusText = "來源與完整路線：第 \(index + 1) / \(workouts.count) 筆…"
                result.scanned += 1
                if keys.uuids.contains(workout.uuid.uuidString) { result.skipped += 1; continue }
                let evidence = await health.calibrationEvidence(of: workout)
                let locations = includeRoutes ? try await health.completeRoute(of: workout) : []
                var type = HealthKitManager.workoutType(for: workout.workoutActivityType, hasRoute: locations.count > 1)
                if evidence.generatedByThisApp, let raw = workout.metadata?["GPSTracker.workoutType"] as? String, let own = WorkoutType(rawValue: raw) { type = own }
                let distance = await health.distance(of: workout)
                let steps = await health.steps(during: workout)
                let energy = await health.energy(of: workout)
                let sport = SportCatalog.sport(for: workout.workoutActivityType)
                // Route processing and geometry calculations do not block the UI.
                let weight = AppSettings.shared.bodyWeight
                let payload = await Task.detached(priority: .utility) {
                    Self.makePayload(workout: workout, type: type, sport: sport, distance: distance,
                                     steps: steps, energy: energy, locations: locations, evidence: evidence, bodyWeight: weight)
                }.value
                if isCancelled || Task.isCancelled { result.cancelled = true; break }
                if keys.identities.contains(where: { $0.matches(payload.identity) }) { result.skipped += 1; continue }
                if try await writer.insert(payload) {
                    keys.uuids.insert(payload.healthKitUUID); keys.identities.append(payload.identity)
                    result.imported += 1
                    if !payload.routePoints.isEmpty { result.withRoute += 1 }
                    result.sources[payload.sourceApp, default: 0] += 1
                    result.oldest = min(result.oldest ?? workout.startDate, workout.startDate)
                    result.newest = max(result.newest ?? workout.startDate, workout.startDate)
                } else { result.skipped += 1 }
                progress = Double(index + 1) / Double(max(1, workouts.count))
                await Task.yield()
            }
        } catch { result.error = "健康讀取或資料庫寫入失敗，已保留原有資料：" + error.localizedDescription }
        result.finishedAt = Date(); lastResult = result
        // Failed/cancelled imports never advance their retry cursor.
        if !result.cancelled && result.error == nil {
            progress = 1
            AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
            Task { await CalibrationCoordinator.shared.analyzeIfEnabled() }
        }
        return result
    }

    /// 背景喚醒用。SwiftData 寫入由 HealthImportWriter 的 ModelActor 執行，
    /// 這個入口不再自己建立主執行緒 ModelContext。
    @MainActor
    @discardableResult
    func importNewInBackground() async -> ImportResult {
        await importNew(existing: [])
    }

    // MARK: 建立紀錄

    private static func makePayload(workout: HKWorkout,
                             type: WorkoutType,
                             sport: SportKind?,
                             distance: Double?,
                             steps: Int?,
                             energy: Double?,
                             locations: [CLLocation],
                             evidence: MeasurementEvidence, bodyWeight: Double) -> HealthImportPayload {
        let duration = workout.duration

        var gain = 0.0
        var loss = 0.0
        var fullRouteDistance = 0.0
        if locations.count > 1 {
            for index in 1..<locations.count {
                let previous = locations[index - 1]
                let current = locations[index]
                let delta = current.altitude - previous.altitude
                if delta > 0.8 { gain += delta } else if delta < -0.8 { loss += -delta }
                fullRouteDistance += current.distance(from: previous)
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
            var derivedSpeed = 0.0
            if let previous {
                let stepDistance = location.distance(from: previous)
                accumulated += stepDistance
                let dt = location.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0 {
                    derivedSpeed = max(0, stepDistance / dt)
                }
            }

            let reportedSpeed = location.speed
            let effectiveSpeed = reportedSpeed.isFinite && reportedSpeed > 0.1
                ? reportedSpeed
                : derivedSpeed

            routePoints.append(HealthImportRoutePoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                timestamp: location.timestamp,
                speed: max(0, effectiveSpeed),
                accuracy: location.horizontalAccuracy,
                distanceFromStart: accumulated
            ))
            previous = location
        }

        return HealthImportPayload(
            evidence: evidence,
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
            routePoints: routePoints
        )
    }

}
