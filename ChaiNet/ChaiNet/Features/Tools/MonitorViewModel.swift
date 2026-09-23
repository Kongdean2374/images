import Foundation
import Observation
import ChaiNetCore
import ChaiNetEngines

/// Continuous ping / network-drop monitor (foreground only — iOS background limits apply).
@MainActor
@Observable
final class MonitorViewModel {
    enum Target: Hashable, Identifiable {
        case server
        case icmp(String)
        case tcp(String)
        var id: String {
            switch self {
            case .server: "server"
            case .icmp(let h): "icmp:\(h)"
            case .tcp(let h): "tcp:\(h)"
            }
        }
        var title: String {
            switch self {
            case .server: "測速伺服器"
            case .icmp(let h): "ICMP \(h)"
            case .tcp(let h): "TCP \(h):443"
            }
        }
    }

    private(set) var samples: [LatencySample] = []
    private(set) var spikes: [LatencySpikeEvent] = []
    private(set) var drops: [NetworkDropEvent] = []
    private(set) var pathChanges: [PathChangeEvent] = []
    private(set) var inDrop = false
    private(set) var running = false
    private(set) var error: String?
    private(set) var savedResult: TestResult?
    var target: Target = .icmp("1.1.1.1")
    var interval: Double = 1.0

    private let engine: any ContinuousPingEngineProtocol
    private let settings: SettingsStore
    private let tasks: TaskRegistry
    private let recorder: ResultRecorder
    private let networkInfo: any NetworkInfoProviding
    private var task: Task<Void, Never>?
    private var registration: UUID?
    private var targetDescription = ""

    init(engine: any ContinuousPingEngineProtocol, settings: SettingsStore, tasks: TaskRegistry, recorder: ResultRecorder,
         networkInfo: any NetworkInfoProviding) {
        self.engine = engine
        self.settings = settings
        self.tasks = tasks
        self.recorder = recorder
        self.networkInfo = networkInfo
    }

    var statistics: LatencyStatistics { LatencyStatistics.compute(from: samples) }
    /// Last 2 minutes for the live chart.
    var recentSamples: [LatencySample] { Array(samples.suffix(Int(120 / max(interval, 0.1)))) }

    func makeProbe() -> any LatencyProbe {
        switch target {
        case .server:
            let server = settings.fixedServer ?? settings.allServers[0]
            if let pair = DefaultLatencyProbeFactory().lossProbe(for: server, payloadSize: 64, ipPreference: settings.settings.ipPreference) {
                return pair.probe
            }
            return HTTPLatencyProbe(url: server.pingURL())
        case .icmp(let host):
            return ICMPEchoProbe(host: host)
        case .tcp(let host):
            return TCPConnectProbe(host: host)
        }
    }

    func start() {
        stop()
        samples = []; spikes = []; drops = []; pathChanges = []; error = nil; inDrop = false; savedResult = nil
        running = true
        let probe = makeProbe()
        targetDescription = probe.targetDescription
        registration = tasks.register { [weak self] in self?.stop() }
        let engine = self.engine
        let interval = self.interval
        task = Task { [weak self] in
            do {
                for try await event in engine.run(probe: probe, interval: interval, duration: nil) {
                    guard let self else { return }
                    switch event {
                    case .sample(let s): self.samples.append(s)
                    case .spike(let s): self.spikes.append(s)
                    case .dropStarted: self.inDrop = true
                    case .dropEnded(let d): self.drops.append(d); self.inDrop = false
                    case .pathChanged(let p): self.pathChanges.append(p)
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            await self?.finish()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func finish() async {
        guard running else { return }
        running = false
        tasks.unregister(registration)
        registration = nil
        guard samples.count >= 5 else { return }
        var result = TestResult(kind: .monitoring, network: await networkInfo.snapshot(includePublicIP: false))
        result.monitoring = MonitoringResult(target: targetDescription, intervalSeconds: interval, samples: samples, statistics: statistics,
                                             spikes: spikes, drops: drops, pathChanges: pathChanges)
        result.evaluate()
        savedResult = await recorder.record(result)
    }
}
