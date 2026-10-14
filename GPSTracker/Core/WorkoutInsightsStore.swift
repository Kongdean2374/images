import Foundation
import SwiftData
import Combine

struct WorkoutInsightsResult: Sendable {
    var efforts: [BestEffort]
    var clusters: [RouteCluster]
    var achievements: [Achievement]
    var integrity: IntegrityReport
}

@ModelActor
private actor WorkoutInsightsReader {
    func read(progress: @Sendable (Int, Int) async -> Void) async throws -> WorkoutInsightsResult {
        let sessions = try modelContext.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startDate, order: .reverse)]))
        var counts: [UUID: Int] = [:]
        var signatures: [UUID: String] = [:]
        var best: [Double: BestEffort] = [:]
        var performanceSessions = 0
        for (index, session) in sessions.enumerated() {
            try Task.checkCancellation()
            let identifier = session.id
            let predicate = #Predicate<RoutePoint> { $0.session?.id == identifier }
            let count = try modelContext.fetchCount(FetchDescriptor<RoutePoint>(predicate: predicate))
            counts[identifier] = count
            if count > 5, let distance = session.totalDistance, distance > 500 {
                var firstQuery = FetchDescriptor<RoutePoint>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
                firstQuery.fetchLimit = 1
                var lastQuery = FetchDescriptor<RoutePoint>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
                lastQuery.fetchLimit = 1
                if let first = try modelContext.fetch(firstQuery).first, let last = try modelContext.fetch(lastQuery).first {
                    signatures[identifier] = RouteClusterEngine.signature(startLatitude: first.latitude, startLongitude: first.longitude,
                        endLatitude: last.latitude, endLongitude: last.longitude, distance: distance)
                }
            }
            if count > 2 && performanceSessions < 200 {
                performanceSessions += 1
                // A short-lived private context releases each workout's route graph.
                // Never fault every historical route into the UI's ModelContext.
                let points: [PerformancePoint] = try autoreleasepool {
                    let routeContext = ModelContext(modelContainer)
                    let query = FetchDescriptor<RoutePoint>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
                    return try routeContext.fetch(query).map { PerformancePoint(timestamp: $0.timestamp, distance: $0.distanceFromStart) }
                }
                for item in BestEffortEngine.standardDistances {
                    if let duration = try PerformanceWindow.fastest(points: points, distance: item.distance),
                       best[item.distance].map({ duration < $0.duration }) ?? true {
                        best[item.distance] = BestEffort(distance: item.distance, label: item.label, duration: duration,
                                                        date: session.startDate, sessionTitle: session.displayTitle)
                    }
                }
            }
            if index % 5 == 0 || index + 1 == sessions.count { await progress(index + 1, sessions.count) }
        }
        try Task.checkCancellation()
        return WorkoutInsightsResult(efforts: best.values.sorted { $0.distance < $1.distance },
            clusters: RouteClusterEngine.cluster(sessions: sessions, signatures: signatures),
            achievements: AchievementEngine.evaluate(sessions: sessions, routeCounts: counts),
            integrity: DataIntegrity.report(sessions: sessions, routeCounts: counts))
    }
}

@MainActor
final class WorkoutInsightsStore: ObservableObject {
    static let shared = WorkoutInsightsStore()
    @Published private(set) var result: WorkoutInsightsResult?
    @Published private(set) var revision = 0
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private var container: ModelContainer?
    private var loadedRevision = -1
    private var task: Task<WorkoutInsightsResult, Error>?
    private var generation = UUID()
    private var changes: AnyCancellable?

    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        changes = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidate() }
        revision += 1
    }
    private func invalidate() { loadedRevision = -1; revision += 1 }
    func loadIfNeeded() async {
        guard let container, loadedRevision != revision, !Task.isCancelled else { return }
        cancel()
        let requestedRevision = revision
        let token = UUID(); generation = token
        isLoading = true; progress = 0; error = nil; status = "正在背景整理運動資料…"
        let task = Task { () throws -> WorkoutInsightsResult in
            let reader = await Task.detached(priority: .utility) { WorkoutInsightsReader(modelContainer: container) }.value
            try Task.checkCancellation()
            return try await reader.read { done, total in
                await MainActor.run {
                    guard self.generation == token else { return }
                    self.progress = Double(done) / Double(max(1, total))
                    self.status = "正在背景分析第 \(done) / \(total) 筆，仍可切換頁面"
                }
            }
        }
        self.task = task
        do {
            let result = try await task.value
            guard !Task.isCancelled, generation == token, requestedRevision == revision else {
                if generation == token { cancel() }
                return
            }
            self.result = result
            loadedRevision = requestedRevision
            isLoading = false; self.task = nil
        } catch {
            guard generation == token else { return }
            isLoading = false; self.task = nil
            if !(error is CancellationError) { self.error = "資料分析未完成：" + error.localizedDescription }
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil; isLoading = false
    }
}
