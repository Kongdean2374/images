import Foundation

struct IntervalConfig: Codable, Equatable {
    var prepareSeconds: Int = 10
    var workSeconds: Int = 30
    var restSeconds: Int = 15
    var rounds: Int = 8

    var totalSeconds: Int {
        prepareSeconds + rounds * (workSeconds + restSeconds)
    }

    /// 轉成通用課表
    var plan: IntervalPlan {
        var segments: [IntervalSegment] = []
        if prepareSeconds > 0 {
            segments.append(IntervalSegment(kind: .prepare, seconds: prepareSeconds))
        }
        segments.append(IntervalSegment(kind: .work, seconds: workSeconds))
        if restSeconds > 0 {
            segments.append(IntervalSegment(kind: .rest, seconds: restSeconds))
        }
        // 預備段只做一次，所以拆成兩個課表結構時用 repeatCount 處理主體
        if prepareSeconds > 0 {
            let body = Array(segments.dropFirst())
            var expanded: [IntervalSegment] = [segments[0]]
            for _ in 0..<max(1, rounds) { expanded.append(contentsOf: body) }
            return IntervalPlan(name: "快速設定", segments: expanded, repeatCount: 1)
        }
        return IntervalPlan(name: "快速設定", segments: segments, repeatCount: max(1, rounds))
    }
}

/// 間歇計時器：支援快速設定與自訂多段課表。
final class IntervalTimerEngine: ObservableObject {

    enum Phase: String {
        case idle, prepare, work, rest, cooldown, finished

        var displayName: String {
            switch self {
            case .idle: return "準備開始"
            case .prepare: return "預備"
            case .work: return "衝刺"
            case .rest: return "休息"
            case .cooldown: return "緩和"
            case .finished: return "完成"
            }
        }
    }

    private struct Step {
        let kind: IntervalSegmentKind
        let name: String
        let seconds: Int
        let round: Int
    }

    @Published var config = IntervalConfig()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var currentRound = 0
    @Published private(set) var totalRounds = 0
    @Published private(set) var totalElapsed: TimeInterval = 0
    @Published private(set) var isPaused = false
    @Published private(set) var completedWorkSeconds: TimeInterval = 0
    @Published private(set) var currentSegmentName = ""
    @Published private(set) var planName = ""
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepCount = 0

    private var steps: [Step] = []
    private var timer: Timer?
    private var phaseEnd: Date?
    private var pausedRemaining: TimeInterval = 0
    private var lastCountdownSpoken = -1
    private(set) var startDate = Date()

    var phaseDuration: TimeInterval {
        guard stepIndex < steps.count else { return 1 }
        return TimeInterval(max(1, steps[stepIndex].seconds))
    }

    var phaseProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / phaseDuration))
    }

    var isRunning: Bool {
        phase != .idle && phase != .finished && !isPaused
    }

    /// 整體進度 0...1
    var overallProgress: Double {
        guard stepCount > 0 else { return 0 }
        return min(1, (Double(stepIndex) + phaseProgress) / Double(stepCount))
    }

    var totalPlannedSeconds: Int {
        steps.reduce(0) { $0 + $1.seconds }
    }

    // MARK: 控制

    func start() {
        start(plan: config.plan)
    }

    func start(plan: IntervalPlan) {
        reset()
        planName = plan.name
        steps = expand(plan)
        stepCount = steps.count
        totalRounds = max(1, steps.map { $0.round }.max() ?? 1)
        guard !steps.isEmpty else { return }
        startDate = Date()
        stepIndex = 0
        enterCurrentStep()
        startTimer()
        LiveActivityController.shared.start(mode: .indoorInterval, usesDistance: false)
    }

    private func expand(_ plan: IntervalPlan) -> [Step] {
        var result: [Step] = []
        let rounds = max(1, plan.repeatCount)
        var roundNumber = 0
        for round in 0..<rounds {
            roundNumber = round + 1
            for segment in plan.segments where segment.seconds > 0 {
                result.append(Step(kind: segment.kind,
                                   name: segment.name,
                                   seconds: segment.seconds,
                                   round: roundNumber))
            }
        }
        // 快速設定會把每一輪展開在同一個 repeat 裡，改用衝刺段計算輪次
        if rounds == 1 {
            var workIndex = 0
            result = result.map { step in
                if step.kind == .work {
                    workIndex += 1
                    return Step(kind: step.kind, name: step.name, seconds: step.seconds, round: workIndex)
                }
                return Step(kind: step.kind, name: step.name, seconds: step.seconds, round: max(1, workIndex))
            }
        }
        return result
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
        guard phase != .idle, phase != .finished else { return }
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
        totalRounds = 0
        totalElapsed = 0
        completedWorkSeconds = 0
        isPaused = false
        phaseEnd = nil
        steps = []
        stepIndex = 0
        stepCount = 0
        currentSegmentName = ""
        planName = ""
        lastCountdownSpoken = -1
    }

    // MARK: 內部

    private func startTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func enterCurrentStep() {
        guard stepIndex < steps.count else {
            finish()
            return
        }
        let step = steps[stepIndex]
        phase = phaseFor(step.kind)
        currentRound = step.round
        currentSegmentName = step.name
        remaining = TimeInterval(step.seconds)
        phaseEnd = Date().addingTimeInterval(remaining)
        lastCountdownSpoken = -1

        switch step.kind {
        case .prepare:
            CueService.shared.speak("預備")
        case .work:
            CueService.shared.speak("\(step.name)，開始")
            CueService.shared.impact(.heavy)
        case .rest:
            CueService.shared.speak("休息")
            CueService.shared.impact(.medium)
        case .cooldown:
            CueService.shared.speak("緩和")
            CueService.shared.impact(.soft)
        }
    }

    private func phaseFor(_ kind: IntervalSegmentKind) -> Phase {
        switch kind {
        case .prepare: return .prepare
        case .work: return .work
        case .rest: return .rest
        case .cooldown: return .cooldown
        }
    }

    private func advance() {
        if stepIndex < steps.count, steps[stepIndex].kind == .work {
            completedWorkSeconds += TimeInterval(steps[stepIndex].seconds)
        }
        stepIndex += 1
        if stepIndex >= steps.count {
            finish()
        } else {
            enterCurrentStep()
        }
    }

    private func finish() {
        phase = .finished
        phaseEnd = nil
        timer?.invalidate()
        timer = nil
        LiveActivityController.shared.end()
        CueService.shared.notify(.success)
        CueService.shared.speak("訓練完成")
    }

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
                                             statusText: "\(phase.displayName) \(Int(ceil(remaining)))s・\(stepIndex + 1)/\(stepCount)",
                                             isPaused: isPaused)
        if remaining <= 0 {
            lastCountdownSpoken = -1
            advance()
        }
    }

    // MARK: 輸出

    func buildSession() -> WorkoutSession {
        let duration = max(totalElapsed, 1)
        let label = planName.isEmpty ? "間歇" : planName
        let session = WorkoutSession(type: .indoorInterval,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: duration,
                                     totalDistance: nil,
                                     averagePace: nil,
                                     routeKey: label,
                                     title: label)
        session.calories = IntensityCalculator.calories(type: .indoorInterval,
                                                        duration: duration,
                                                        bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: .indoorInterval,
                                                           duration: duration,
                                                           distance: nil,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        let doneSteps = min(stepIndex, stepCount)
        session.notes = "\(label)：完成 \(doneSteps) / \(stepCount) 段，衝刺累計 \(Fmt.duration(completedWorkSeconds))"
        let workSteps = steps.enumerated().filter { $0.element.kind == .work && $0.offset < stepIndex }
        session.laps = workSteps.enumerated().map { index, item in
            LapRecord(lapNumber: index + 1,
                      lapDuration: TimeInterval(item.element.seconds),
                      distanceOverride: nil,
                      timestamp: startDate.addingTimeInterval(Double(index) * Double(item.element.seconds)))
        }
        return session
    }
}
