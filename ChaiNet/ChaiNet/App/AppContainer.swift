import Foundation
import Observation
import ChaiNetCore
import ChaiNetEngines

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, speedTest, tools, diagnostics, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "首頁"
        case .speedTest: "測速"
        case .tools: "工具"
        case .diagnostics: "診斷"
        case .history: "歷史"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .speedTest: "speedometer"
        case .tools: "wrench.and.screwdriver.fill"
        case .diagnostics: "stethoscope"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape.fill"
        }
    }
}

/// Every running async task registers here so the app can cancel them all when it goes to the
/// background (iOS suspends networking, results would be invalid).
@MainActor
@Observable
final class TaskRegistry {
    private var cancellers: [UUID: @MainActor () -> Void] = [:]

    var runningCount: Int { cancellers.count }

    func register(_ cancel: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        cancellers[id] = cancel
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        cancellers.removeValue(forKey: id)
    }

    func cancelAll() {
        let all = cancellers
        cancellers.removeAll()
        for cancel in all.values { cancel() }
    }
}

/// Attaches opt-in location and persists results.
@MainActor
final class ResultRecorder {
    let history: any HistoryStoring
    let settings: SettingsStore
    let location: LocationService

    init(history: any HistoryStoring, settings: SettingsStore, location: LocationService) {
        self.history = history
        self.settings = settings
        self.location = location
    }

    @discardableResult
    func record(_ result: TestResult) async -> TestResult {
        var r = result
        if settings.settings.storeLocation, r.location == nil {
            r.location = await location.currentLocation()
        }
        try? history.save(r)
        return r
    }
}

/// Composition root: owns engines (behind protocols), stores and long-lived view models.
@MainActor
@Observable
final class AppContainer {
    let settings: SettingsStore
    let history: any HistoryStoring
    let runner: any TestRunnerProtocol
    let networkInfo: any NetworkInfoProviding
    let monitorEngine: any ContinuousPingEngineProtocol
    let serverDirectory: any ServerDirectoryProtocol
    let analyzer: any RootCauseAnalyzing
    let reportGenerator: DiagnosticReportGenerator
    let location: LocationService
    let tasks: TaskRegistry
    let recorder: ResultRecorder
    /// Speed test VM lives here so a running test survives tab switches.
    let speedTest: RunViewModel

    var selectedTab: AppTab = .home
    var currentNetwork: NetworkSnapshot?
    /// Set by other screens to open a result or session.
    var pendingSessionID: UUID?

    init(history: any HistoryStoring, settings: SettingsStore = SettingsStore(),
         runner: any TestRunnerProtocol = TestRunner(),
         networkInfo: any NetworkInfoProviding = NetworkInfoProvider(),
         monitorEngine: any ContinuousPingEngineProtocol = ContinuousPingEngine(),
         serverDirectory: any ServerDirectoryProtocol = ServerDirectory(),
         analyzer: any RootCauseAnalyzing = RootCauseAnalyzer()) {
        self.settings = settings
        self.history = history
        self.runner = runner
        self.networkInfo = networkInfo
        self.monitorEngine = monitorEngine
        self.serverDirectory = serverDirectory
        self.analyzer = analyzer
        self.reportGenerator = DiagnosticReportGenerator()
        self.location = LocationService()
        let tasks = TaskRegistry()
        self.tasks = tasks
        let recorder = ResultRecorder(history: history, settings: settings, location: location)
        self.recorder = recorder
        self.speedTest = RunViewModel(runner: runner, settings: settings, tasks: tasks, recorder: recorder)
    }

    /// Keeps `currentNetwork` live while the app is in the foreground.
    func observeNetwork() async {
        currentNetwork = await networkInfo.snapshot(includePublicIP: false)
        for await snapshot in networkInfo.pathUpdates() {
            currentNetwork = snapshot
        }
    }

    func applyRetention() {
        try? history.applyRetention(days: settings.settings.historyRetention.days)
    }

    /// Baselines from local history, excluding the given result IDs (so a test is never
    /// compared against itself).
    func baselines(excluding ids: Set<UUID> = []) -> BaselineStore {
        BaselineEngine().build(from: history.allResults().filter { !ids.contains($0.id) })
    }

    func makeRunViewModel() -> RunViewModel {
        RunViewModel(runner: runner, settings: settings, tasks: tasks, recorder: recorder)
    }

    var onCellular: Bool { currentNetwork?.primaryInterface == .cellular }
}
