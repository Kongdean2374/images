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
private struct HealthImportRoutePoint: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double
    let distanceFromStart: Double
}

private struct HealthImportPayload: Sendable {
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
    var fingerprints: Set<String>
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
            fingerprints: Set(sessions.map {
                "\($0.typeRaw)-\(Int($0.startDate.timeIntervalSince1970 / 60))"
            })
        )
    }

    func insert(_ payload: HealthImportPayload) throws {
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
        session.notes = "自 \(payload.sourceApp) 匯入"

        if !payload.routePoints.isEmpty {
            session.routePoints = payload.routePoints.map { point in
                RoutePoint(latitude: point.latitude,
                           longitude: point.longitude,
                           altitude: point.altitude,
                           timestamp: point.timestamp,
                           speed: point.speed,
                           distanceFromStart: point.distanceFromStart)
            }
        }

        modelContext.insert(session)
        try modelContext.save()
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

    /// 單一 HealthKit route 若異常巨大，限制持久化點數，避免一次匯入數萬個 SwiftData model。
    /// 6000 點對一般數小時運動仍保有很高的軌跡細節。
    private let maxRoutePointsPerWorkout = 6000

    /// 中斷匯入。每一筆完成後就會立即存檔，已完成的紀錄不會遺失。
    @MainActor
    func cancel() {
        guard isImporting else { return }
        isCancelled = true
        statusText = "正在安全中斷…"
    }

    @MainActor
    func configure(container: ModelContainer) {
        writer = HealthImportWriter(modelContainer: container)
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
    func importWorkouts(range: ImportRange,
                        existing: [WorkoutSession],
                        includeRoutes: Bool = true) async -> ImportResult {
        guard health.isReady else {
            statusText = health.availability.displayName
            return ImportResult()
        }
        guard let writer else {
            statusText = "資料庫尚未就緒"
            return ImportResult()
        }
        guard !isImporting else { return ImportResult() }

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
        var keys = await currentImportKeys(writer: writer, fallback: existing)

        for (index, workout) in workouts.enumerated() {
            if isCancelled {
                result.finishedAt = Date()
                lastResult = result
                return result
            }

            progress = Double(index) / Double(workouts.count)
            statusText = "處理第 \(index + 1) / \(workouts.count) 筆…"

            let uuid = workout.uuid.uuidString
            if keys.uuids.contains(uuid) {
                result.skipped += 1
                continue
            }

            let locations = includeRoutes ? await health.route(of: workout) : []
            let type = HealthKitManager.workoutType(for: workout.workoutActivityType,
                                                    hasRoute: locations.count > 1)
            let sport = SportCatalog.sport(for: workout.workoutActivityType)
            let fp = fingerprint(type: type, start: workout.startDate)
            if keys.fingerprints.contains(fp) {
                result.skipped += 1
                continue
            }

            let distance = await health.distance(of: workout)
            let steps = await health.steps(during: workout)
            let energy = await health.energy(of: workout)
            let payload = makePayload(workout: workout,
                                      type: type,
                                      sport: sport,
                                      distance: distance,
                                      steps: steps,
                                      energy: energy,
                                      locations: locations)

            do {
                // 真正昂貴的 SwiftData graph insert 在 ModelActor 執行，不再卡 UI runloop。
                try await writer.insert(payload)
            } catch {
                DiagnosticsLog.shared.log(.error,
                                          category: "health-import",
                                          "健康資料匯入寫入失敗",
                                          detail: ["錯誤": error.localizedDescription,
                                                   "來源": payload.sourceApp,
                                                   "開始": Fmt.dateTime(payload.startDate)])
                result.finishedAt = Date()
                lastResult = result
                return result
            }

            // 成功後立刻更新去重集合，避免同一批 HealthKit 結果互相重複。
            keys.uuids.insert(uuid)
            keys.fingerprints.insert(fp)

            result.imported += 1
            if !payload.routePoints.isEmpty { result.withRoute += 1 }
            result.sources[payload.sourceApp, default: 0] += 1
            if result.oldest == nil || workout.startDate < result.oldest! { result.oldest = workout.startDate }
            if result.newest == nil || workout.startDate > result.newest! { result.newest = workout.startDate }

            progress = Double(index + 1) / Double(workouts.count)
            await Task.yield()
        }

        progress = 1
        result.finishedAt = Date()
        lastResult = result
        AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
        return result
    }

    /// 只抓上次匯入之後的新紀錄（App 啟動與背景更新用）
    @MainActor
    @discardableResult
    func importNew(existing: [WorkoutSession]) async -> ImportResult {
        guard health.isReady, let writer else { return ImportResult() }
        guard !isImporting else { return ImportResult() }

        isImporting = true
        isCancelled = false
        progress = 0
        statusText = "檢查最新健康資料…"
        defer {
            isImporting = false
            isCancelled = false
            statusText = ""
        }

        let since = AppSettings.shared.lastHealthImportDate
            ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())
            ?? Date()

        let workouts = await health.workouts(from: since.addingTimeInterval(-3600))
        guard !workouts.isEmpty else {
            AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
            return ImportResult()
        }

        var result = ImportResult()
        var keys = await currentImportKeys(writer: writer, fallback: existing)

        for (index, workout) in workouts.enumerated() {
            if isCancelled { break }

            progress = Double(index) / Double(workouts.count)

            let uuid = workout.uuid.uuidString
            if keys.uuids.contains(uuid) {
                result.skipped += 1
                continue
            }

            let locations = await health.route(of: workout)
            let type = HealthKitManager.workoutType(for: workout.workoutActivityType,
                                                    hasRoute: locations.count > 1)
            let sport = SportCatalog.sport(for: workout.workoutActivityType)
            let fp = fingerprint(type: type, start: workout.startDate)
            if keys.fingerprints.contains(fp) {
                result.skipped += 1
                continue
            }

            let distance = await health.distance(of: workout)
            let steps = await health.steps(during: workout)
            let energy = await health.energy(of: workout)
            let payload = makePayload(workout: workout,
                                      type: type,
                                      sport: sport,
                                      distance: distance,
                                      steps: steps,
                                      energy: energy,
                                      locations: locations)

            do {
                try await writer.insert(payload)
            } catch {
                DiagnosticsLog.shared.log(.error,
                                          category: "health-import",
                                          "最新健康資料寫入失敗",
                                          detail: ["錯誤": error.localizedDescription,
                                                   "來源": payload.sourceApp])
                break
            }

            keys.uuids.insert(uuid)
            keys.fingerprints.insert(fp)

            result.imported += 1
            if !payload.routePoints.isEmpty { result.withRoute += 1 }
            result.sources[payload.sourceApp, default: 0] += 1
            if result.oldest == nil || workout.startDate < result.oldest! { result.oldest = workout.startDate }
            if result.newest == nil || workout.startDate > result.newest! { result.newest = workout.startDate }

            progress = Double(index + 1) / Double(workouts.count)
            await Task.yield()
        }

        result.finishedAt = Date()
        AppSettings.shared.lastHealthImport = Date().timeIntervalSince1970
        if result.imported > 0 { lastResult = result }
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

    @MainActor
    private func makePayload(workout: HKWorkout,
                             type: WorkoutType,
                             sport: SportKind?,
                             distance: Double?,
                             steps: Int?,
                             energy: Double?,
                             locations: [CLLocation]) -> HealthImportPayload {
        let duration = workout.endDate.timeIntervalSince(workout.startDate)

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
                                                               bodyWeight: AppSettings.shared.bodyWeight)
        let intensity = IntensityCalculator.score(met: met,
                                                  duration: duration,
                                                  distance: effectiveDistance,
                                                  averagePace: pace,
                                                  elevationGain: locations.count > 1 ? gain : nil)

        let compacted = compactRoute(locations)
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
                distanceFromStart: accumulated
            ))
            previous = location
        }

        // 抽稀後幾何距離可能稍短，用健康 App 的總距離校正每個點的累積距離。
        if let effectiveDistance, accumulated > 0, !routePoints.isEmpty {
            let factor = effectiveDistance / accumulated
            routePoints = routePoints.map { point in
                HealthImportRoutePoint(latitude: point.latitude,
                                       longitude: point.longitude,
                                       altitude: point.altitude,
                                       timestamp: point.timestamp,
                                       speed: point.speed,
                                       distanceFromStart: point.distanceFromStart * factor)
            }
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
            routePoints: routePoints
        )
    }

    /// 等距抽樣，保留第一點與最後一點。只處理異常巨大的 HealthKit route。
    private func compactRoute(_ locations: [CLLocation]) -> [CLLocation] {
        guard locations.count > maxRoutePointsPerWorkout,
              maxRoutePointsPerWorkout > 2 else { return locations }

        let lastIndex = locations.count - 1
        let denominator = Double(maxRoutePointsPerWorkout - 1)
        var result: [CLLocation] = []
        result.reserveCapacity(maxRoutePointsPerWorkout)

        var previousIndex = -1
        for step in 0..<maxRoutePointsPerWorkout {
            let raw = Double(step) * Double(lastIndex) / denominator
            let index = min(lastIndex, max(0, Int(raw.rounded())))
            guard index != previousIndex else { continue }
            result.append(locations[index])
            previousIndex = index
        }

        if result.last?.timestamp != locations.last?.timestamp, let last = locations.last {
            result.append(last)
        }
        return result
    }

    @MainActor
    private func currentImportKeys(writer: HealthImportWriter,
                                   fallback existing: [WorkoutSession]) async -> HealthImportKeys {
        if let keys = try? await writer.existingKeys() {
            return keys
        }
        return HealthImportKeys(
            uuids: Set(existing.compactMap { $0.healthKitUUID }),
            fingerprints: Set(existing.map { fingerprint(type: $0.type, start: $0.startDate) })
        )
    }

    private func fingerprint(type: WorkoutType, start: Date) -> String {
        "\(type.rawValue)-\(Int(start.timeIntervalSince1970 / 60))"
    }
}
