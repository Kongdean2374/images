import Foundation
import Combine

/// 走路 / 跑步 / 跑步機模式：完全不需要定位，
/// 用計步器 + 氣壓計 + 動作辨識組出距離、爬升與走跑分段。
final class StepWorkoutEngine: ObservableObject {

    enum State: String { case idle, running, paused, finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var steps: Int = 0
    @Published private(set) var cadence: Double = 0
    @Published private(set) var distance: Double = 0
    @Published private(set) var distanceSource: DistanceSource = .stride
    @Published private(set) var floorsAscended: Int = 0
    @Published private(set) var floorsDescended: Int = 0
    @Published private(set) var elevationGain: Double = 0
    @Published private(set) var elevationLoss: Double = 0
    @Published private(set) var currentMotion: MotionKind = .unknown
    @Published var mode: WorkoutType = .walk

    let pedometer = PedometerManager()
    let altimeter = AltimeterManager()
    let motion = ActivityTypeDetector()

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var announcedKM = 0
    private(set) var startDate = Date()

    init() {
        bind()
    }

    // MARK: 衍生數值

    var averagePace: Double? {
        guard distance > 50, elapsed > 0 else { return nil }
        return elapsed / (distance / 1000)
    }

    var strideProfile: StrideProfile { mode.strideProfile }

    var strideLength: Double { StrideCalibration.stride(strideProfile) }

    var calories: Double {
        IntensityCalculator.calories(type: mode, duration: elapsed, bodyWeight: AppSettings.shared.bodyWeight)
    }

    var isCalibrated: Bool { StrideCalibration.isCalibrated(strideProfile) }

    // MARK: 控制

    func start(mode: WorkoutType) {
        self.mode = mode
        reset()
        startDate = Date()
        segmentStart = Date()
        state = .running

        pedometer.start(from: startDate)
        altimeter.start()
        motion.start()
        startTimer()
        LiveActivityController.shared.start(mode: mode, usesDistance: false)

        CueService.shared.impact(.heavy)
        CueService.shared.speak("\(mode.displayName)開始")
    }

    func pause() {
        guard state == .running else { return }
        commit()
        state = .paused
        LiveActivityController.shared.update(elapsed: elapsed,
                                             distance: distance,
                                             steps: steps,
                                             pace: averagePace,
                                             statusText: "已暫停",
                                             isPaused: true,
                                             force: true)
        CueService.shared.impact(.light)
    }

    func resume() {
        guard state == .paused else { return }
        segmentStart = Date()
        state = .running
        CueService.shared.impact(.light)
    }

    func stop() {
        commit()
        timer?.invalidate()
        timer = nil
        pedometer.stop()
        altimeter.stop()
        motion.stop()
        state = .finished
        LiveActivityController.shared.end()
        CueService.shared.speak("記錄結束")
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
        steps = 0
        cadence = 0
        distance = 0
        floorsAscended = 0
        floorsDescended = 0
        elevationGain = 0
        elevationLoss = 0
        accumulated = 0
        announcedKM = 0
        segmentStart = nil
        altimeter.reset()
        state = .idle
    }

    // MARK: 內部

    private func bind() {
        pedometer.$steps
            .sink { [weak self] value in
                guard let self, self.state == .running || self.state == .paused else { return }
                self.steps = value
                self.recalculateDistance()
            }
            .store(in: &cancellables)

        pedometer.$cadence
            .sink { [weak self] value in self?.cadence = value }
            .store(in: &cancellables)

        pedometer.$estimatedDistance
            .sink { [weak self] _ in self?.recalculateDistance() }
            .store(in: &cancellables)

        pedometer.$floorsAscended
            .sink { [weak self] value in self?.floorsAscended = value }
            .store(in: &cancellables)

        pedometer.$floorsDescended
            .sink { [weak self] value in self?.floorsDescended = value }
            .store(in: &cancellables)

        altimeter.$gain
            .sink { [weak self] value in self?.elevationGain = value }
            .store(in: &cancellables)

        altimeter.$loss
            .sink { [weak self] value in self?.elevationLoss = value }
            .store(in: &cancellables)

        motion.$current
            .sink { [weak self] value in self?.currentMotion = value }
            .store(in: &cancellables)
    }

    /// 距離優先序：個人步幅（已校正） → 系統估算 → 預設步幅
    private func recalculateDistance() {
        guard steps > 0 else { return }
        if StrideCalibration.isCalibrated(strideProfile) {
            distance = StrideCalibration.distance(steps: steps, profile: strideProfile)
            distanceSource = .stride
        } else if let systemDistance = pedometer.estimatedDistance, systemDistance > 0 {
            distance = systemDistance
            distanceSource = .pedometer
        } else {
            distance = StrideCalibration.distance(steps: steps, profile: strideProfile)
            distanceSource = .stride
        }
        announceKMIfNeeded()
    }

    private func announceKMIfNeeded() {
        let km = Int(distance / 1000)
        guard km > announcedKM else { return }
        announcedKM = km
        CueService.shared.impact(.medium)
        CueService.shared.speak("已完成 \(km) 公里")
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard state == .running, let segmentStart else { return }
        elapsed = accumulated + Date().timeIntervalSince(segmentStart)
        LiveActivityController.shared.update(elapsed: elapsed,
                                             distance: distance,
                                             steps: steps,
                                             pace: averagePace,
                                             statusText: currentMotion == .unknown
                                                ? mode.displayName : currentMotion.displayName,
                                             isPaused: false)
    }

    private func commit() {
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        segmentStart = nil
        elapsed = accumulated
    }

    // MARK: 輸出

    /// 跑步機模式結束後可輸入實際距離，順便校正個人步幅
    func applyActualDistance(_ actual: Double) {
        guard actual > 0 else { return }
        distance = actual
        distanceSource = .manual
        StrideCalibration.calibrate(withActualDistance: actual, steps: steps, profile: strideProfile)
    }

    func buildSession() -> WorkoutSession {
        let durations = motion.durations()
        let session = WorkoutSession(type: mode,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: elapsed,
                                     totalDistance: distance > 0 ? distance : nil,
                                     averagePace: averagePace,
                                     elevationGain: altimeter.isAvailable ? elevationGain : nil,
                                     elevationLoss: altimeter.isAvailable ? elevationLoss : nil,
                                     stepCount: steps,
                                     cadence: cadence,
                                     floorsAscended: floorsAscended,
                                     floorsDescended: floorsDescended,
                                     strideLength: strideLength,
                                     walkingSeconds: durations.walking > 0 ? durations.walking : nil,
                                     runningSeconds: durations.running > 0 ? durations.running : nil,
                                     distanceSource: distanceSource,
                                     routeKey: mode == .treadmill ? "跑步機" : nil)
        session.calories = calories
        session.intensityScore = IntensityCalculator.score(type: mode,
                                                           duration: elapsed,
                                                           distance: distance,
                                                           averagePace: averagePace,
                                                           elevationGain: elevationGain)
        return session
    }
}
