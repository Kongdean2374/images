import Foundation
import SwiftData

struct HeavyAnalyticsResult: Sendable {
    let routeClusters: [RouteCluster]
    let racePredictions: [RacePrediction]
    let balance: IntensityBalance
    let integrity: IntegrityReport
}

@ModelActor
actor AnalysisDataWorker {
    private var cachedKey: String?
    private var cachedEfforts: [BestEffort] = []
    private var cachedHeavy: HeavyAnalyticsResult?
    private var cachedRouteCount = 0

    private func sessions() throws -> [WorkoutSession] {
        try modelContext.fetch(FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))
    }

    private func refreshIfNeeded(key: String) throws -> [WorkoutSession] {
        if cachedKey != key {
            cachedKey = key
            cachedEfforts = []
            cachedHeavy = nil
            cachedRouteCount = 0
        }
        return try sessions()
    }

    func bestEfforts(key: String) throws -> [BestEffort] {
        if cachedKey == key, !cachedEfforts.isEmpty {
            return cachedEfforts
        }
        let all = try refreshIfNeeded(key: key)
        let efforts = BestEffortEngine.evaluate(sessions: all)
        cachedEfforts = efforts
        return efforts
    }

    func routeCount(key: String) throws -> Int {
        if cachedKey == key, cachedRouteCount > 0 {
            return cachedRouteCount
        }
        let all = try refreshIfNeeded(key: key)
        let count = all.reduce(into: 0) { result, session in
            if !session.routePoints.isEmpty { result += 1 }
        }
        cachedRouteCount = count
        return count
    }

    func heavyAnalytics(key: String) throws -> HeavyAnalyticsResult {
        if cachedKey == key, let cachedHeavy {
            return cachedHeavy
        }

        let all = try refreshIfNeeded(key: key)
        let efforts: [BestEffort]
        if cachedEfforts.isEmpty {
            efforts = BestEffortEngine.evaluate(sessions: all)
            cachedEfforts = efforts
        } else {
            efforts = cachedEfforts
        }

        let result = HeavyAnalyticsResult(
            routeClusters: RouteClusterEngine.cluster(sessions: all),
            racePredictions: RacePredictionEngine.predictions(from: efforts),
            balance: IntensityBalanceEngine.evaluate(sessions: all),
            integrity: DataIntegrity.report(sessions: all)
        )
        cachedRouteCount = all.reduce(into: 0) { result, session in
            if !session.routePoints.isEmpty { result += 1 }
        }
        cachedHeavy = result
        return result
    }
}

/// SwiftUI 畫面只拿值型別結果，不把 SwiftData model 丟到 detached task。
/// 真正會 fault 大量 routePoints、排序與掃描的工作全在 ModelActor 執行。
@MainActor
final class AnalysisDataService {
    static let shared = AnalysisDataService()

    private var workerTask: Task<AnalysisDataWorker, Never>?

    private init() {}

    func configure(container: ModelContainer) {
        guard workerTask == nil else { return }
        workerTask = Task.detached(priority: .utility) {
            AnalysisDataWorker(modelContainer: container)
        }
    }

    func bestEfforts(key: String) async -> [BestEffort] {
        guard let workerTask else { return [] }
        do {
            return try await workerTask.value.bestEfforts(key: key)
        } catch {
            DiagnosticsLog.shared.log(.error,
                                      category: "analysis",
                                      "背景最佳成績分析失敗",
                                      detail: ["錯誤": error.localizedDescription])
            return []
        }
    }

    func routeCount(key: String) async -> Int {
        guard let workerTask else { return 0 }
        do {
            return try await workerTask.value.routeCount(key: key)
        } catch {
            DiagnosticsLog.shared.log(.error,
                                      category: "analysis",
                                      "背景軌跡統計失敗",
                                      detail: ["錯誤": error.localizedDescription])
            return 0
        }
    }

    func heavyAnalytics(key: String) async -> HeavyAnalyticsResult? {
        guard let workerTask else { return nil }
        do {
            return try await workerTask.value.heavyAnalytics(key: key)
        } catch {
            DiagnosticsLog.shared.log(.error,
                                      category: "analysis",
                                      "背景分析失敗",
                                      detail: ["錯誤": error.localizedDescription])
            return nil
        }
    }
}
