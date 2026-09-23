import Foundation
import Observation
import ChaiNetCore
import ChaiNetEngines

/// Drives one test run (speed test, a single tool, a custom profile, a quality test) and exposes
/// live progress. All work is cancellable: `stop()`, leaving a tool screen, and the app entering
/// the background all cancel the underlying task.
@MainActor
@Observable
final class RunViewModel {
    enum Status: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var phase: TestPhase?
    private(set) var completedPhases: [TestPhase] = []
    private(set) var network: NetworkSnapshot?
    private(set) var server: ServerDescriptor?
    private(set) var downloadSamples: [SpeedSample] = []
    private(set) var uploadSamples: [SpeedSample] = []
    private(set) var latencySamples: [TestPhase: [LatencySample]] = [:]
    private(set) var streams: [TransferDirection: Int] = [:]
    private(set) var traceHops: [TracerouteHop] = []
    /// Partial while running, final afterwards.
    private(set) var result: TestResult?
    private(set) var configuration: TestRunConfiguration?

    private let runner: any TestRunnerProtocol
    private let settings: SettingsStore
    private let tasks: TaskRegistry
    private let recorder: ResultRecorder
    private var task: Task<Void, Never>?
    private var registration: UUID?
    /// Persist results automatically (tools and speed tests do; diagnostic sessions persist themselves).
    var persistResults = true

    init(runner: any TestRunnerProtocol, settings: SettingsStore, tasks: TaskRegistry, recorder: ResultRecorder) {
        self.runner = runner
        self.settings = settings
        self.tasks = tasks
        self.recorder = recorder
    }

    var isRunning: Bool { status == .running }

    // MARK: Live derived values

    var activeDirection: TransferDirection? {
        switch phase {
        case .download: .download
        case .upload: .upload
        default: nil
        }
    }

    /// Current rate: mean of the last 5 samples (0.5 s) for a readable, still responsive number.
    func currentMbps(_ direction: TransferDirection) -> Double? {
        let s = samples(direction).suffix(5)
        guard !s.isEmpty else { return nil }
        return SpeedMath.mbps(bytes: s.reduce(0) { $0 + $1.intervalBytes }, seconds: s.reduce(0) { $0 + $1.intervalDuration })
    }

    func liveSummary(_ direction: TransferDirection) -> SpeedSummary? {
        let s = samples(direction)
        guard !s.isEmpty else { return nil }
        return SpeedCalculator.summarize(samples: s)
    }

    func samples(_ direction: TransferDirection) -> [SpeedSample] {
        direction == .download ? downloadSamples : uploadSamples
    }

    var idleLatencyLive: LatencyStatistics? {
        guard let s = latencySamples[.idleLatency], !s.isEmpty else { return nil }
        return LatencyStatistics.compute(from: s)
    }

    // MARK: Control

    /// Builds a configuration from the current settings.
    func makeConfiguration(kind: TestKind, items: Set<TestItem>, onCellular: Bool) -> TestRunConfiguration {
        let s = settings.settings
        switch kind {
        case .gaming, .voice, .streaming, .obsUpload:
            return .quality(kind, servers: settings.allServers, fixedServer: settings.fixedServer, settings: s, onCellular: onCellular)
        default:
            return TestRunConfiguration(kind: kind, items: items, candidateServers: settings.allServers, fixedServer: settings.fixedServer,
                                        settings: s, onCellular: onCellular)
        }
    }

    func start(kind: TestKind, items: Set<TestItem>, onCellular: Bool, adjust: ((inout TestRunConfiguration) -> Void)? = nil,
               completion: (@MainActor @Sendable (TestResult) -> Void)? = nil) {
        var config = makeConfiguration(kind: kind, items: items, onCellular: onCellular)
        adjust?(&config)
        start(config, completion: completion)
    }

    func start(_ config: TestRunConfiguration, completion: (@MainActor @Sendable (TestResult) -> Void)? = nil) {
        stop()
        reset()
        configuration = config
        status = .running
        registration = tasks.register { [weak self] in self?.stop() }
        let runner = runner
        task = Task { [weak self] in
            do {
                for try await event in runner.run(config) {
                    guard let self else { return }
                    self.handle(event)
                }
                guard let self else { return }
                if Task.isCancelled {
                    await self.finishCancelled()
                } else if var final = self.result {
                    if self.persistResults { final = await self.recorder.record(final) }
                    self.result = final
                    self.status = .finished
                    completion?(final)
                }
            } catch is CancellationError {
                await self?.finishCancelled()
            } catch {
                guard let self else { return }
                if Task.isCancelled {
                    await self.finishCancelled()
                } else {
                    self.status = .failed(error.localizedDescription)
                }
            }
            self?.tasks.unregister(self?.registration)
            self?.registration = nil
        }
    }

    /// Cancels the run; whatever was measured is kept (marked cancelled).
    func stop() {
        task?.cancel()
        task = nil
    }

    func reset() {
        status = .idle
        phase = nil
        completedPhases = []
        network = nil
        server = nil
        downloadSamples = []
        uploadSamples = []
        latencySamples = [:]
        streams = [:]
        traceHops = []
        result = nil
    }

    private func finishCancelled() async {
        guard status == .running else { return }
        status = .cancelled
        if var partial = result {
            partial.wasCancelled = true
            partial.evaluate()
            result = partial
            // Partial results are saved so the user can still inspect them, clearly marked.
            if persistResults, partial.download != nil || partial.idleLatency != nil {
                result = await recorder.record(partial)
            }
        }
        tasks.unregister(registration)
        registration = nil
    }

    private func handle(_ event: TestRunEvent) {
        switch event {
        case .phase(let p):
            if let current = phase, current != p { completedPhases.append(current) }
            phase = p
        case .network(let n):
            network = n
        case .serverSelected(let s):
            server = s
        case .latencySample(let p, let s):
            latencySamples[p, default: []].append(s)
        case .speedSample(let d, let s):
            if d == .download { downloadSamples.append(s) } else { uploadSamples.append(s) }
        case .streams(let d, let n):
            streams[d] = n
        case .traceHop(let hop):
            traceHops.append(hop)
        case .partial(let r):
            result = r
        case .completed(let r):
            result = r
        }
    }
}
