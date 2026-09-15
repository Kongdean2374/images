import Foundation
import CoreMotion

/// 棒式／靜態撐體計時：用動作感測器判斷是否還穩定撐著。
final class PlankEngine: ObservableObject {

    enum State: String { case idle, holding, finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0（晃動劇烈）～ 1（非常穩）
    @Published private(set) var stability: Double = 1
    @Published private(set) var shakeSeconds: TimeInterval = 0
    @Published var targetSeconds: Int = 60
    @Published var autoStopOnBreak = true
    @Published private(set) var isAvailable = true

    private let motion = CMMotionManager()
    private var timer: Timer?
    private var startTime = Date()
    private var smoothedMovement: Double = 0
    private var brokenSince: Date?
    private var spokenMilestone = 0

    var progress: Double {
        targetSeconds > 0 ? min(1, elapsed / Double(targetSeconds)) : 0
    }

    var reachedTarget: Bool {
        elapsed >= Double(targetSeconds)
    }

    var stabilityLabel: String {
        switch stability {
        case ..<0.4: return "晃動明顯"
        case ..<0.7: return "稍有晃動"
        case ..<0.9: return "穩定"
        default: return "非常穩"
        }
    }

    // MARK: 控制

    func start() {
        reset()
        isAvailable = motion.isDeviceMotionAvailable
        startTime = Date()
        state = .holding
        spokenMilestone = 0

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let a = data.userAcceleration
                let r = data.rotationRate
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                    + sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 0.12
                DispatchQueue.main.async { self?.ingest(magnitude) }
            }
        }

        startTimer()
        CueService.shared.impact(.heavy)
        CueService.shared.speak("開始撐體")
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
        state = .finished
        CueService.shared.notify(.success)
        CueService.shared.speak("撐體結束，共 \(Int(elapsed)) 秒")
    }

    func reset() {
        motion.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
        state = .idle
        elapsed = 0
        stability = 1
        shakeSeconds = 0
        smoothedMovement = 0
        brokenSince = nil
    }

    // MARK: 內部

    private func startTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func ingest(_ magnitude: Double) {
        smoothedMovement = smoothedMovement * 0.82 + magnitude * 0.18
        // 0.06 以下視為完全穩定，0.45 以上視為姿勢已散
        stability = min(1, max(0, 1 - (smoothedMovement - 0.06) / 0.39))

        guard state == .holding else { return }
        if stability < 0.25 {
            if let since = brokenSince {
                if Date().timeIntervalSince(since) > 1.3, autoStopOnBreak {
                    stop()
                }
            } else {
                brokenSince = Date()
            }
        } else {
            brokenSince = nil
        }
    }

    private func tick() {
        guard state == .holding else { return }
        elapsed = Date().timeIntervalSince(startTime)
        if stability < 0.5 { shakeSeconds += 0.1 }
        announceIfNeeded()
    }

    private func announceIfNeeded() {
        let seconds = Int(elapsed)
        if seconds >= targetSeconds, spokenMilestone < targetSeconds {
            spokenMilestone = targetSeconds
            CueService.shared.notify(.success)
            CueService.shared.speak("達成目標")
            return
        }
        let milestone = (seconds / 30) * 30
        if milestone > spokenMilestone, milestone > 0 {
            spokenMilestone = milestone
            CueService.shared.impact(.medium)
            CueService.shared.speak("\(milestone) 秒")
        }
    }

    // MARK: 輸出

    func buildSession(exerciseName: String) -> WorkoutSession {
        let duration = max(elapsed, 1)
        let session = WorkoutSession(type: .plank,
                                     startDate: startTime,
                                     endDate: Date(),
                                     duration: duration,
                                     totalDistance: nil,
                                     averagePace: nil,
                                     routeKey: exerciseName,
                                     title: exerciseName)
        session.calories = IntensityCalculator.calories(type: .plank,
                                                        duration: duration,
                                                        bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: .plank,
                                                           duration: duration,
                                                           distance: nil,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        session.notes = String(format: "%@：撐 %.0f 秒（目標 %d 秒）　穩定度 %.0f%%",
                               exerciseName, duration, targetSeconds,
                               max(0, 100 - shakeSeconds / max(1, duration) * 100))
        return session
    }
}
