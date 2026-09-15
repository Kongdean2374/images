import Foundation

struct IntervalConfig: Codable, Equatable {
    var prepareSeconds: Int = 10
    var workSeconds: Int = 30
    var restSeconds: Int = 15
    var rounds: Int = 8

    var totalSeconds: Int {
        prepareSeconds + rounds * (workSeconds + restSeconds)
    }
}

/// 間歇訓練計時器：完全不需定位。
final class IntervalTimerEngine: ObservableObject {

    enum Phase: String {
        case idle, prepare, work, rest, finished

        var displayName: String {
            switch self {
            case .idle: return "準備開始"
            case .prepare: return "預備"
            case .work: return "衝刺"
            case .rest: return "休息"
            case .finished: return "完成"
            }
        }
    }

    @Published var config = IntervalConfig()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var currentRound = 0
    @Published private(set) var totalElapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var completedWorkSeconds: TimeInterval = 0

    private var timer: Timer?
    private var phaseEnd: Date?
    private var pausedRemaining: TimeInterval = 0
    private(set) var startDate = Date()

    var phaseDuration: TimeInterval {
        switch phase {
        case .prepare: return TimeInterval(config.prepareSeconds)
        case .work: return TimeInterval(config.workSeconds)
        case .rest: return TimeInterval(config.restSeconds)
        default: return 1
        }
    }

    var phaseProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / phaseDuration))
    }

    var isRunning: Bool {
        phase != .idle && phase != .finished && !isPaused
    }

    // MARK: 控制

    func start() {
        reset()
        startDate = Date()
        currentRound = 1
        enter(config.prepareSeconds > 0 ? .prepare : .work)
        startTimer()
        LiveActivityController.shared.start(mode: .indoorInterval, usesDistance: false)
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        pausedRemaining = remaining
        phaseEnd = nil
        CueService.shared.impact(.light)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        phaseEnd = Date().addingTimeInterval(pausedRemaining)
        CueService.shared.impact(.light)
    }

    func skipPhase() {
        guard phase == .work || phase == .rest || phase == .prepare else { return }
        advance()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phase = .finished
        phaseEnd = nil
        LiveActivityController.shared.end()
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        phase = .idle
        remaining = 0
        currentRound = 0
        totalElapsed = 0
        completedWorkSeconds = 0
        isPaused = false
        phaseEnd = nil
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func enter(_ next: Phase) {
        phase = next
        remaining = phaseDuration
        phaseEnd = Date().addingTimeInterval(remaining)
        switch next {
        case .prepare:
            CueService.shared.speak("預備")
        case .work:
            CueService.shared.speak("第 \(currentRound) 組，開始")
            CueService.shared.impact(.heavy)
        case .rest:
            CueService.shared.speak("休息")
            CueService.shared.impact(.medium)
        default:
            break
        }
    }

    private func advance() {
        switch phase {
        case .prepare:
            enter(.work)
        case .work:
            completedWorkSeconds += TimeInterval(config.workSeconds)
            if currentRound >= config.rounds {
                finish()
            } else if config.restSeconds > 0 {
                enter(.rest)
            } else {
                currentRound += 1
                enter(.work)
            }
        case .rest:
            currentRound += 1
            if currentRound > config.rounds {
                finish()
            } else {
                enter(.work)
            }
        default:
            break
        }
    }

    private func finish() {
        phase = .finished
        phaseEnd = nil
        timer?.invalidate()
        timer = nil
        LiveActivityController.shared.end()
        CueService.shared.notify(.success)
        CueService.shared.speak("訓練完成，共 \(config.rounds) 組")
    }

    private var lastCountdownSpoken = -1

    private func tick() {
        guard let phaseEnd, !isPaused else { return }
        totalElapsed = Date().timeIntervalSince(startDate)
        remaining = max(0, phaseEnd.timeIntervalSinceNow)

        let whole = Int(ceil(remaining))
        if whole <= 3, whole > 0, whole != lastCountdownSpoken {
            lastCountdownSpoken = whole
            CueService.shared.impact(.rigid)
        }
        LiveActivityController.shared.update(elapsed: totalElapsed,
                                             distance: 0,
                                             steps: 0,
                                             pace: nil,
                                             statusText: "\(phase.displayName) \(Int(ceil(remaining)))s・第 \(min(currentRound, config.rounds))/\(config.rounds) 組",
                                             isPaused: isPaused)
        if remaining <= 0 {
            lastCountdownSpoken = -1
            advance()
        }
    }

    // MARK: 輸出

    func buildSession() -> WorkoutSession {
        let duration = max(totalElapsed, 1)
        let session = WorkoutSession(type: .indoorInterval,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: duration,
                                     totalDistance: nil,
                                     averagePace: nil,
                                     routeKey: "間歇 \(config.workSeconds)/\(config.restSeconds)×\(config.rounds)")
        session.calories = IntensityCalculator.calories(type: .indoorInterval,
                                                        duration: duration,
                                                        bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: .indoorInterval,
                                                           duration: duration,
                                                           distance: nil,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        session.notes = "完成 \(min(currentRound, config.rounds)) / \(config.rounds) 組"
        session.laps = (1...max(1, min(currentRound, config.rounds))).map {
            LapRecord(lapNumber: $0,
                      lapDuration: TimeInterval(config.workSeconds),
                      distanceOverride: nil,
                      timestamp: startDate.addingTimeInterval(Double($0) * Double(config.workSeconds + config.restSeconds)))
        }
        return session
    }
}
