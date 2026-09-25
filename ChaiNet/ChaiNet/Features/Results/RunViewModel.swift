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
    /// Extreme Stress Test: current phase / round / node and running traffic.
    private(set) var stressProgress: StressProgress?
    /// Readable live values, refreshed every 0.5 s (not every 100 ms sample) so the big number
    /// doesn't flicker.
    private(set) var displayMbps: [TransferDirection: Double] = [:]
    private(set) var displaySummary: [TransferDirection: SpeedSummary] = [:]
    /// Smooth count between readouts: the value shown at the last update and when it changed.
    private(set) var displayFrom: [TransferDirection: Double] = [:]
    private(set) var displayChangedAt: [TransferDirection: Date] = [:]
    /// Arrival time of the latest throughput sample (the live chart interpolates between samples).
    private(set) var lastSampleAt: [TransferDirection: Date] = [:]
    /// Later phases (DNS, IPv4 / IPv6, MTU…): live series, labelled values and Chinese notes.
    private(set) var liveSeries: [TestPhase: [String: [LatencySample]]] = [:]
    private(set) var liveSeriesOrder: [TestPhase: [String]] = [:]
    private(set) var liveValues: [TestPhase: [LiveValue]] = [:]
    private(set) var notes: [TestPhase: [LiveNote]] = [:]
    private(set) var phaseStartedAt: Date?

    struct LiveValue: Identifiable, Equatable {
        var label: String
        var value: Double
        var unit: String
        var id: String { label }
    }

    struct LiveNote: Identifiable, Equatable {
        var id: Int
        var text: String
    }
    private var noteCounter = 0
    /// Partial while running, final afterwards.
    private(set) var result: TestResult?
    private(set) var configuration: TestRunConfiguration?
    private(set) var startedAt: Date?

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

    /// Display refresh cadence in samples (5 × 100 ms = 0.5 s).
    static let displayEvery = 5
    /// Live notes kept per phase.
    static let maxNotes = 6

    var activeDirection: TransferDirection? {
        switch phase {
        case .download: .download
        case .upload: .upload
        default: nil
        }
    }

    /// Readout eased from the previous value to the current one over `countDuration`
    /// (ease-out), so the big number glides at display refresh rate instead of jumping.
    static let countDuration = 0.45

    func animatedMbps(_ direction: TransferDirection, at date: Date) -> Double? {
        guard let target = displayMbps[direction] else { return nil }
        guard let from = displayFrom[direction], let at = displayChangedAt[direction] else { return target }
        let t = min(1, max(0, date.timeIntervalSince(at) / Self.countDuration))
        let eased = 1 - pow(1 - t, 3)
        return from + (target - from) * eased
    }

    /// Current rate: mean of the last 5 samples (0.5 s) for a readable, still responsive number.
    func currentMbps(_ direction: TransferDirection) -> Double? {
        // Same adaptive window as the statistics: upload progress batching must not show 0 / spikes.
        let all = samples(direction)
        let s = all.suffix(SpeedCalculator.batching(all).windowSamples)
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

    /// Feature whose ⚙︎ overrides apply to this run (nil = global settings only).
    var featureID: String?

    /// Builds a configuration from the global settings plus this feature's overrides:
    /// test duration for every phase, parallel connections, IP family, servers (single /
    /// multiple / auto-multiple) and multi-point validation.
    func makeConfiguration(kind: TestKind, items: Set<TestItem>, onCellular: Bool) -> TestRunConfiguration {
        let s = settings.settings.effective(for: featureID)
        let plan = s.serverPlan(available: settings.allServers)
        var config: TestRunConfiguration
        switch kind {
        case .gaming, .voice, .streaming, .obsUpload:
            config = .quality(kind, servers: settings.allServers, fixedServer: plan.primary, settings: s, onCellular: onCellular)
        default:
            config = TestRunConfiguration(kind: kind, items: items, candidateServers: settings.allServers, fixedServer: plan.primary,
                                          settings: s, onCellular: onCellular)
        }
        config.additionalServers = plan.extras
        config.autoAdditionalServerCount = plan.autoExtraCount
        if s.multiPointValidation, !config.items.isDisjoint(with: [.ping, .jitter, .packetLoss, .burstLoss, .download, .upload]) {
            config.items.insert(.crossValidation)
        }
        config.applyTiming()
        return config
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
        startedAt = Date()
        status = .running
        registration = tasks.register { [weak self] in self?.stop() }
        let runner = self.runner
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
        stressProgress = nil
        displayMbps = [:]
        displaySummary = [:]
        displayFrom = [:]
        displayChangedAt = [:]
        lastSampleAt = [:]
        liveSeries = [:]
        liveSeriesOrder = [:]
        liveValues = [:]
        notes = [:]
        phaseStartedAt = nil
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
            if phase != p { phaseStartedAt = Date() }
            phase = p
        case .network(let n):
            network = n
        case .serverSelected(let s):
            server = s
        case .latencySample(let p, let s):
            latencySamples[p, default: []].append(s)
        case .speedSample(let d, let s):
            if d == .download { downloadSamples.append(s) } else { uploadSamples.append(s) }
            let now = Date()
            lastSampleAt[d] = now
            let count = samples(d).count
            if count == 1 || count % Self.displayEvery == 0 {
                let next = currentMbps(d)
                displayFrom[d] = animatedMbps(d, at: now) ?? next
                displayChangedAt[d] = now
                displayMbps[d] = next
                displaySummary[d] = liveSummary(d)
            }
        case .streams(let d, let n):
            streams[d] = n
        case .traceHop(let hop):
            traceHops.append(hop)
        case .stressProgress(let p):
            // The runner re-sends the current phase about once a second with fresh data-usage
            // counters. Only a *new* phase (another transfer) starts a fresh live timeline —
            // clearing on every update blanked the chart and speed every second.
            let newPhase = stressProgress?.phaseIndex != p.phaseIndex
            stressProgress = p
            guard newPhase else { break }
            for (kind, d) in [(StressPhaseKind.downloadStress, TransferDirection.download), (.uploadStress, .upload)] where p.kind == kind {
                if d == .download { downloadSamples = [] } else { uploadSamples = [] }
                displayMbps[d] = nil
                displaySummary[d] = nil
                displayFrom[d] = nil
                displayChangedAt[d] = nil
                lastSampleAt[d] = nil
            }
        case .liveSample(let p, let series, let sample):
            if liveSeries[p]?[series] == nil { liveSeriesOrder[p, default: []].append(series) }
            liveSeries[p, default: [:]][series, default: []].append(sample)
        case .liveValue(let p, let label, let value, let unit):
            var values = liveValues[p] ?? []
            if let i = values.firstIndex(where: { $0.label == label }) { values[i].value = value } else { values.append(LiveValue(label: label, value: value, unit: unit)) }
            liveValues[p] = values
        case .note(let p, let text):
            noteCounter += 1
            var list = notes[p] ?? []
            list.append(LiveNote(id: noteCounter, text: text))
            notes[p] = Array(list.suffix(Self.maxNotes))
        case .partial(let r):
            result = r
        case .completed(let r):
            result = r
        }
    }
}
