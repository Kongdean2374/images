import Foundation

/// 體能測驗執行引擎：倒數預備 → 計時／計次 → 結果。完全不需要定位。
final class FitnessTestEngine: ObservableObject {

    enum Phase: String {
        case idle, countdown, running, finished
    }

    @Published var item: FitnessTestItem = .sitUps
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var countdown: Int = 3
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var detectedReps: Int = 0
    @Published var manualReps: Int = 0
    @Published private(set) var laps: Int = 0
    @Published var lapDistance: Double = 400
    @Published private(set) var estimatedDistance: Double = 0

    let detector = RepDetector()
    let pedometer = PedometerManager()

    private var timer: Timer?
    private var startTime = Date()
    private var lastSpokenMilestone = 0
    private var cancellableReps = 0

    var totalReps: Int { detectedReps + manualReps }

    /// 3000 公尺的完成進度
    var runProgress: Double {
        min(1, estimatedDistance / 3000)
    }

    var isTimed: Bool { item.timeLimit != nil }

    /// 成績：計次項目為次數，跑步為秒數
    var resultValue: Double {
        isTimed ? Double(totalReps) : elapsed
    }

    // MARK: 控制

    func prepare(item: FitnessTestItem) {
        self.item = item
        reset()
        phase = .countdown
        countdown = 3
        CueService.shared.speak("預備")
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.countdown -= 1
                if self.countdown <= 0 {
                    timer.invalidate()
                    self.begin()
                } else {
                    CueService.shared.impact(.rigid)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func begin() {
        timer?.invalidate()
        startTime = Date()
        elapsed = 0
        remaining = item.timeLimit ?? 0
        phase = .running
        detector.reset()

        switch item {
        case .sitUps:
            detector.sensitivity = 1.05
            detector.start()
        case .pushUps:
            detector.sensitivity = 0.95
            detector.start()
        case .run3000:
            pedometer.start(from: Date())
        }

        CueService.shared.impact(.heavy)
        CueService.shared.speak("開始")
        startTimer()
    }

    func addLap() {
        guard phase == .running, item == .run3000 else { return }
        laps += 1
        CueService.shared.notify(.success)
        CueService.shared.speak("第 \(laps) 圈")
        recalcDistance()
    }

    func removeLap() {
        guard laps > 0 else { return }
        laps -= 1
        recalcDistance()
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        detector.stop()
        pedometer.stop()
        phase = .finished
        CueService.shared.notify(.success)
        CueService.shared.speak("測驗結束")
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        detector.stop()
        detector.reset()
        pedometer.stop()
        phase = .idle
        elapsed = 0
        remaining = 0
        detectedReps = 0
        manualReps = 0
        laps = 0
        estimatedDistance = 0
        lastSpokenMilestone = 0
    }

    // MARK: 內部

    private func startTimer() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard phase == .running else { return }
        elapsed = Date().timeIntervalSince(startTime)
        detectedReps = detector.repCount

        if let limit = item.timeLimit {
            remaining = max(0, limit - elapsed)
            announceTimeMilestones()
            if remaining <= 0 { finish() }
        } else {
            recalcDistance()
            announceDistanceMilestones()
            if estimatedDistance >= 3000 { finish() }
        }
    }

    private func recalcDistance() {
        // 手動計圈優先（最準），其次用個人步幅換算，最後才用系統估算
        let lapDistanceTotal = Double(laps) * lapDistance
        if lapDistanceTotal > 0 {
            estimatedDistance = lapDistanceTotal
            return
        }
        let steps = pedometer.steps
        if steps > 0 {
            estimatedDistance = StrideCalibration.distance(steps: steps, profile: .running)
        } else if let system = pedometer.estimatedDistance {
            estimatedDistance = system
        }
    }

    private func announceTimeMilestones() {
        let whole = Int(remaining)
        if whole == 60, lastSpokenMilestone != 60 {
            lastSpokenMilestone = 60
            CueService.shared.speak("剩下一分鐘，目前 \(totalReps) 下")
        } else if whole == 30, lastSpokenMilestone != 30 {
            lastSpokenMilestone = 30
            CueService.shared.speak("剩下三十秒")
        } else if whole == 10, lastSpokenMilestone != 10 {
            lastSpokenMilestone = 10
            CueService.shared.speak("剩下十秒")
        }
    }

    private func announceDistanceMilestones() {
        let milestone = Int(estimatedDistance / 500)
        if milestone > lastSpokenMilestone {
            lastSpokenMilestone = milestone
            CueService.shared.impact(.medium)
            CueService.shared.speak("\(milestone * 500) 公尺，用時 \(Int(elapsed / 60)) 分 \(Int(elapsed) % 60) 秒")
        }
    }

    // MARK: 輸出

    func buildSession(standards: FitnessStandards) -> WorkoutSession {
        let grade = standards.grade(for: item, value: resultValue)
        let duration = isTimed ? min(elapsed, item.timeLimit ?? elapsed) : elapsed
        let session = WorkoutSession(type: .fitnessTest,
                                     startDate: startTime,
                                     endDate: Date(),
                                     duration: duration,
                                     totalDistance: item == .run3000 ? estimatedDistance : nil,
                                     averagePace: item == .run3000 && estimatedDistance > 100
                                        ? duration / (estimatedDistance / 1000) : nil,
                                     stepCount: item == .run3000 && pedometer.steps > 0 ? pedometer.steps : nil,
                                     repCount: isTimed ? totalReps : nil,
                                     distanceSource: item == .run3000
                                        ? (laps > 0 ? .lap : .stride) : nil,
                                     routeKey: item.displayName,
                                     title: "\(item.displayName)　\(grade.displayName)")
        session.calories = item.met * AppSettings.shared.bodyWeight * (duration / 3600)
        session.intensityScore = IntensityCalculator.score(type: .fitnessTest,
                                                           duration: duration,
                                                           distance: session.totalDistance,
                                                           averagePace: session.averagePace,
                                                           elevationGain: nil)
        session.notes = isTimed
            ? "\(item.displayName)：\(totalReps) 下（\(grade.displayName)）"
            : "\(item.displayName)：\(Fmt.duration(duration))（\(grade.displayName)）"
        return session
    }
}
