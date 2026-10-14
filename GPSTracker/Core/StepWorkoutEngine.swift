import Foundation
import Combine
import UIKit

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
    @Published var target: WorkoutTarget = .none
    /// 負重行軍的負重（公斤）
    @Published var loadWeight: Double?
    @Published var carryPosition: CarryPosition = .unknown
    private var accumulator = StepDistanceAccumulator()
    private(set) var windows: [EstimateWindow] = []
    private(set) var pauseLog: [Date] = []
    private var lastWindowDate: Date?
    private var stableProfile: StrideProfile = .walking
    private var pendingProfile: StrideProfile?
    private var pendingSince: Date?
    private var baselineStrides: [StrideProfile: Double] = [:]
    private var baselineCalibrated: [StrideProfile: Bool] = [:]
    private var actualDistanceConfirmed = false
    private var stepAlignmentReliable = true
    private var committedFloorsUp = 0
    private var committedFloorsDown = 0
    @Published private(set) var targetReached = false

    let pedometer = PedometerManager()
    let altimeter = AltimeterManager()
    let motion = ActivityTypeDetector()

    private var cancellables = Set<AnyCancellable>()
    private let announcer = AnnouncementService()
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

    var strideLength: Double { steps > 0 ? distance / Double(steps) : StrideCalibration.stride(strideProfile) }

    var calories: Double {
        let bodyWeight = AppSettings.shared.bodyWeight
        // A single load contribution; unknown remains nil in storage and exports.
        return IntensityCalculator.calories(type: mode, duration: elapsed,
                                            bodyWeight: bodyWeight + max(0, loadWeight ?? 0))
    }

    var isCalibrated: Bool { StrideCalibration.isCalibrated(strideProfile) }

    var targetProgress: Double {
        target.progress(distance: distance, steps: steps, duration: elapsed,
                        calories: calories, floors: floorsAscended)
    }

    var targetRemainingText: String {
        target.remainingText(distance: distance,
                             steps: steps,
                             duration: elapsed,
                             calories: calories,
                             floors: floorsAscended,
                             unit: AppSettings.shared.unit)
    }

    private func checkTarget() {
        guard target.isActive, !targetReached, targetProgress >= 1 else { return }
        targetReached = true
        CueService.shared.notify(.success)
        CueService.shared.speak("目標達成")
    }

    // MARK: 控制

    func start(mode: WorkoutType, target: WorkoutTarget = .none) {
        let requested = target
        self.mode = mode
        reset()
        self.target = requested
        startDate = Date()
        segmentStart = Date()
        state = .running
        stableProfile = mode.strideProfile
        for profile in [StrideProfile.walking, .running, .ruck] {
            baselineStrides[profile] = StrideCalibration.stride(profile)
            baselineCalibrated[profile] = StrideCalibration.isCalibrated(profile) || (profile == .ruck && StrideCalibration.isCalibrated(.walking))
        }
        lastWindowDate = startDate

        pedometer.start(from: startDate)
        altimeter.start()
        motion.start()
        startTimer()
        LiveActivityController.shared.start(mode: mode, usesDistance: false)
        announcer.reset()
        if AppSettings.shared.keepScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }

        CueService.shared.impact(.heavy)
        CueService.shared.speak("\(mode.displayName)開始")
    }

    func pause() {
        guard state == .running else { return }
        noteStepBoundary()
        commit()
        pauseLog.append(Date())
        motion.pause()
        altimeter.stop()
        pedometer.stop()
        committedFloorsUp = floorsAscended
        committedFloorsDown = floorsDescended
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
        pauseLog.append(segmentStart!)
        accumulator.rebase()
        lastWindowDate = segmentStart
        motion.resume(at: segmentStart!)
        altimeter.start(preservingTotals: true)
        state = .running
        pedometer.start(from: segmentStart!)
        CueService.shared.impact(.light)
    }

    func stop() {
        if state == .running { noteStepBoundary() }
        commit()
        timer?.invalidate()
        timer = nil
        pedometer.stop()
        altimeter.stop()
        motion.stop()
        state = .finished
        UIApplication.shared.isIdleTimerDisabled = false
        LiveActivityController.shared.end()
        CueService.shared.speak("記錄結束")
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        accumulator = StepDistanceAccumulator()
        actualDistanceConfirmed = false
        stepAlignmentReliable = true
        windows = []
        pauseLog = []
        pendingProfile = nil
        pendingSince = nil
        committedFloorsUp = 0
        committedFloorsDown = 0
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
        targetReached = false
        altimeter.reset()
        state = .idle
    }

    // MARK: 內部

    private func noteStepBoundary() {
        guard let update = pedometer.update, Date().timeIntervalSince(update.endDate) <= 5 else { stepAlignmentReliable = false; return }
    }

    private func bind() {
        pedometer.$update
            .sink { [weak self] update in
                guard let self, self.state == .running, let update else { return }
                self.ingest(update)
            }.store(in: &cancellables)

        altimeter.$gain
            .sink { [weak self] value in if self?.state == .running { self?.elevationGain = value } }
            .store(in: &cancellables)

        altimeter.$loss
            .sink { [weak self] value in if self?.state == .running { self?.elevationLoss = value } }
            .store(in: &cancellables)

        motion.$current
            .sink { [weak self] value in self?.currentMotion = value }
            .store(in: &cancellables)
    }

    private func ingest(_ update: PedometerManager.Update) {
        guard let activeStart = segmentStart, update.endDate >= activeStart else { return }
        // Motion evidence with hysteresis chooses validated whole-workout baselines.
        // There are no fabricated cadence/stride curves without aligned window truth.
        let requested: StrideProfile = mode == .ruck ? .ruck : currentMotion == .running ? .running : currentMotion == .walking ? .walking : mode.strideProfile
        if requested != stableProfile {
            if pendingProfile != requested { pendingProfile = requested; pendingSince = update.endDate }
            if let since = pendingSince, update.endDate.timeIntervalSince(since) >= 8 { stableProfile = requested; pendingProfile = nil }
        } else { pendingProfile = nil; pendingSince = nil }
        let suppressed = motion.confidence > 0 && [.automotive, .cycling, .stationary].contains(currentMotion)
        guard let increment = accumulator.ingest(rawSteps: update.steps, systemDistance: update.distance,
                                                  cadence: update.cadence, date: update.endDate,
                                                  stride: baselineStrides[stableProfile] ?? StrideCalibration.defaultStride(stableProfile),
                                                  calibrated: baselineCalibrated[stableProfile] ?? false, suppress: suppressed) else {
            lastWindowDate = update.endDate
            return
        }
        let source = increment.system ? DistanceSource.pedometer : .stride
        windows.append(EstimateWindow(start: lastWindowDate ?? activeStart, end: update.endDate,
                                      steps: increment.steps, distance: increment.distance, cadence: update.cadence,
                                      profile: stableProfile.rawValue, source: source.rawValue, motion: currentMotion.rawValue))
        lastWindowDate = update.endDate
        steps = accumulator.steps; distance = accumulator.distance
        cadence = accumulator.smoothedCadence ?? 0
        distanceSource = Set(windows.map(\.source)).count > 1 ? .mixed : source
        floorsAscended = committedFloorsUp + update.floorsUp
        floorsDescended = committedFloorsDown + update.floorsDown
        announceIfNeeded(); checkTarget()
    }

    private func announceIfNeeded() {
        announcer.announceIfNeeded(distance: distance,
                                   elapsed: elapsed,
                                   averagePace: averagePace,
                                   currentPace: nil,
                                   pacerDelta: nil)
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
        checkTarget()
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
    func applyActualDistance(_ actual: Double, externallyMeasured: Bool = false) {
        guard actual > 0 else { return }
        distance = actual
        actualDistanceConfirmed = externallyMeasured
        distanceSource = .manual
        // User entry alone is not proof of an externally measured distance.
        // Preserve the entered history; it does not bypass model validation.
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
                                     stepCount: steps > 0 || pedometer.update != nil ? steps : nil,
                                     cadence: elapsed > 0 && steps > 0 ? Double(steps) / elapsed * 60 : nil,
                                     floorsAscended: floorsAscended,
                                     floorsDescended: floorsDescended,
                                     strideLength: steps > 0 ? distance / Double(steps) : nil,
                                     walkingSeconds: durations.walking > 0 ? durations.walking : nil,
                                     runningSeconds: durations.running > 0 ? durations.running : nil,
                                     distanceSource: distanceSource,
                                     routeKey: mode == .treadmill ? "跑步機" : nil)
        session.calories = calories
        session.loadWeight = loadWeight
        if let loadWeight { AppSettings.shared.ruckLoad = loadWeight }
        session.carryPositionRaw = carryPosition.rawValue
        session.pauseLog = pauseLog.isEmpty ? nil : pauseLog
        session.otherSeconds = max(0, elapsed - durations.walking - durations.running)
        session.estimateWindowsJSON = (try? JSONEncoder().encode(windows)).flatMap { String(data: $0, encoding: .utf8) }
        var evidence = MeasurementEvidence()
        evidence.method = distanceSource == .pedometer ? .systemEstimate : distanceSource == .mixed ? .mixed : distanceSource == .manual ? .unknown : .strideEstimate
        if distanceSource == .manual && actualDistanceConfirmed { evidence.method = .knownDistance; evidence.distanceConfirmed = true }
        evidence.sourceBundle = Bundle.main.bundleIdentifier
        evidence.generatedByThisApp = true
        evidence.originSessionID = session.id.uuidString
        evidence.stepSource = "CoreMotion"
        evidence.stepsAligned = stepAlignmentReliable
        evidence.carryPosition = carryPosition
        evidence.loadWeight = loadWeight
        evidence.pauseIntervals = WorkoutTime.pauses(start: startDate, end: session.endDate, log: pauseLog)
        session.evidence = evidence
        session.intensityScore = IntensityCalculator.score(type: mode,
                                                           duration: elapsed,
                                                           distance: distance,
                                                           averagePace: averagePace,
                                                           elevationGain: elevationGain)
        return session
    }
}
