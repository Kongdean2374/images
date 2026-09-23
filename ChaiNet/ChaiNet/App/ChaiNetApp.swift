import SwiftUI
import BackgroundTasks
import ChaiNetCore
import ChaiNetEngines

@main
struct ChaiNetApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let history: any HistoryStoring
        do {
            history = try SwiftDataHistoryStore()
        } catch {
            // Corrupt store: fall back to memory so the app still works; data of this run isn't kept.
            history = (try? SwiftDataHistoryStore(inMemory: true))!
        }
        _container = State(initialValue: AppContainer(history: history))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(container.settings)
                .preferredColorScheme(colorScheme)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // iOS suspends sockets in the background: stop measurements cleanly (partial
                // results are kept and marked as cancelled) and schedule an optional short check.
                container.tasks.cancelAll()
                if container.settings.settings.backgroundChecks { BackgroundChecks.schedule() }
            case .active:
                container.applyRetention()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundChecks.identifier)) {
            await BackgroundChecks.run()
        }
    }

    private var colorScheme: ColorScheme? {
        switch container.settings.settings.appearance {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// Background checks — within iOS limits.
///
/// iOS does **not** allow continuous background monitoring. `BGAppRefreshTask` runs at times the
/// system chooses (typically a few times per day, depending on usage and battery), for about
/// 30 seconds. ChaiNet uses it for one short latency check and never claims per-second
/// background monitoring.
enum BackgroundChecks {
    static let identifier = "app.chainet.ios.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        let server = ServerDescriptor.builtIn[0]
        let probe = HTTPLatencyProbe(url: server.pingURL())
        do {
            try await probe.prepare()
        } catch {
            await probe.close()
            return
        }
        let samples = await LatencySampler.collect(probe: probe, count: 10, interval: 0.5, timeout: 2)
        await probe.close()
        let snapshot = await NetworkInfoProvider().snapshot(includePublicIP: false)
        var result = TestResult(kind: .monitoring, network: snapshot)
        result.server = server
        result.idleLatency = LatencyStatistics.compute(from: samples)
        result.idleSamples = samples
        result.notes.append("背景檢查（由 iOS 排程，約 5 秒）")
        result.evaluate()
        await MainActor.run {
            if let store = try? SwiftDataHistoryStore() { try? store.save(result) }
        }
    }
}
