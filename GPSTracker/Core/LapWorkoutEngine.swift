import Foundation

struct LapDraft: Identifiable, Hashable {
    let id = UUID()
    var number: Int
    var duration: TimeInterval
    var distance: Double
    var timestamp: Date

    var pace: Double? {
        distance > 0 ? duration / (distance / 1000) : nil
    }
}

/// 營區計圈：完全不需定位，純計時 + 計數。
final class LapWorkoutEngine: ObservableObject {

    enum State: String { case idle, running, paused, finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var laps: [LapDraft] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentLapElapsed: TimeInterval = 0
    @Published var lapDistance: Double = AppSettings.shared.lapDistance

    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var lapAccumulated: TimeInterval = 0
    private var lapSegmentStart: Date?
    private(set) var startDate = Date()

    var totalDistance: Double {
        laps.reduce(0) { $0 + $1.distance }
    }

    var averagePace: Double? {
        guard totalDistance > 0, elapsed > 0 else { return nil }
        return elapsed / (totalDistance / 1000)
    }

    var lastLapPace: Double? { laps.last?.pace }

    var bestLap: LapDraft? {
        laps.filter { $0.pace != nil }.min { ($0.pace ?? .infinity) < ($1.pace ?? .infinity) }
    }

    // MARK: 控制

    func start() {
        reset()
        startDate = Date()
        segmentStart = Date()
        lapSegmentStart = Date()
        state = .running
        startTimer()
        LiveActivityController.shared.start(mode: .lapCounter, usesDistance: true)
        CueService.shared.impact(.heavy)
        CueService.shared.speak("計圈開始")
    }

    func recordLap() {
        guard state == .running || state == .paused else { return }
        let lapTime = lapAccumulated + (lapSegmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        let lap = LapDraft(number: laps.count + 1,
                           duration: lapTime,
                           distance: lapDistance,
                           timestamp: Date())
        laps.append(lap)
        lapAccumulated = 0
        lapSegmentStart = state == .running ? Date() : nil
        currentLapElapsed = 0
        CueService.shared.notify(.success)
        CueService.shared.speak("第 \(lap.number) 圈，\(Fmt.duration(lapTime))")
    }

    func undoLastLap() {
        guard !laps.isEmpty else { return }
        laps.removeLast()
        CueService.shared.impact(.rigid)
    }

    func pause() {
        guard state == .running else { return }
        commit()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        segmentStart = Date()
        lapSegmentStart = Date()
        state = .running
    }

    func stop() {
        commit()
        timer?.invalidate()
        timer = nil
        state = .finished
        LiveActivityController.shared.end()
        CueService.shared.speak("計圈結束")
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        laps = []
        elapsed = 0
        currentLapElapsed = 0
        accumulated = 0
        lapAccumulated = 0
        segmentStart = nil
        lapSegmentStart = nil
        state = .idle
    }

    private func commit() {
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        if let lapSegmentStart { lapAccumulated += Date().timeIntervalSince(lapSegmentStart) }
        segmentStart = nil
        lapSegmentStart = nil
        elapsed = accumulated
        currentLapElapsed = lapAccumulated
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard state == .running else { return }
        if let segmentStart { elapsed = accumulated + Date().timeIntervalSince(segmentStart) }
        if let lapSegmentStart { currentLapElapsed = lapAccumulated + Date().timeIntervalSince(lapSegmentStart) }
        LiveActivityController.shared.update(elapsed: elapsed,
                                             distance: totalDistance,
                                             steps: 0,
                                             pace: averagePace,
                                             statusText: "第 \(laps.count + 1) 圈",
                                             isPaused: false)
    }

    // MARK: 輸出

    func buildSession(steps: Int?, cadence: Double?) -> WorkoutSession {
        let session = WorkoutSession(type: .lapCounter,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: elapsed,
                                     totalDistance: totalDistance > 0 ? totalDistance : nil,
                                     averagePace: averagePace,
                                     stepCount: steps,
                                     cadence: cadence,
                                     routeKey: "圈道 \(Int(lapDistance)) 公尺")
        session.calories = IntensityCalculator.calories(type: .lapCounter,
                                                        duration: elapsed,
                                                        bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: .lapCounter,
                                                           duration: elapsed,
                                                           distance: totalDistance,
                                                           averagePace: averagePace,
                                                           elevationGain: nil)
        session.laps = laps.map {
            LapRecord(lapNumber: $0.number,
                      lapDuration: $0.duration,
                      distanceOverride: $0.distance,
                      timestamp: $0.timestamp)
        }
        return session
    }
}
