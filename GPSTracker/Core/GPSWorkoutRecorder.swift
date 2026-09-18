import Foundation
import CoreLocation
import Combine
import SwiftUI
import UIKit

/// 軌跡取樣點（記錄期間的輕量結構，結束後才轉成 SwiftData）
struct TrackSample: Identifiable, Hashable {
    let id = UUID()
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date
    var speed: Double
    var distanceFromStart: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// GPS 追蹤錄製器：距離、配速、海拔、即時軌跡。
final class GPSWorkoutRecorder: ObservableObject {

    enum RecordingState: String {
        case idle, recording, paused, finished
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var samples: [TrackSample] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var distance: Double = 0
    @Published private(set) var currentPace: Double?
    @Published private(set) var averagePace: Double?
    @Published private(set) var elevationGain: Double = 0
    @Published private(set) var elevationLoss: Double = 0
    @Published private(set) var currentAltitude: Double = 0
    @Published private(set) var currentSpeed: Double = 0
    @Published private(set) var heading: Double = 0
    @Published private(set) var isAutoPaused = false
    @Published var workoutType: WorkoutType = .gpsRun
    /// 多項運動時的運動種類（決定熱量 MET 與寫入健康的類型）
    @Published var sport: SportKind?
    @Published var routeKey: String = ""
    /// 虛擬配速員的目標配速（秒/公里），nil 表示不啟用
    @Published var targetPace: Double?
    /// 自動分圈距離（公尺），0 表示關閉
    @Published var autoLapDistance: Double = 1000
    @Published private(set) var laps: [LapDraft] = []

    var startDate: Date = Date()

    private let location = LocationManager.shared
    private let settings = AppSettings.shared
    /// GPS 場次同時計步，用來學習個人步幅（供無定位模式換算距離）
    let pedometer = PedometerManager()
    let altimeter = AltimeterManager()
    private let kalman = GPSKalmanFilter()
    private let announcer = AnnouncementService()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    /// 暫停／繼續的時間點，成對出現；寫進健康 App 讓它算出正確的訓練時間
    private(set) var pauseLog: [Date] = []
    private var lastAccepted: TrackSample?
    private var lastAltitude: Double?
    private var announcedKM = 0
    private var lowSpeedSince: Date?
    private var lastLapDistance: Double = 0
    private var lastLapElapsed: TimeInterval = 0

    /// 最近 25 秒的滑動窗口，用於即時配速
    private let paceWindow: TimeInterval = 25

    // MARK: 控制

    func start(type: WorkoutType) {
        workoutType = type
        reset()
        startDate = Date()
        segmentStart = Date()
        state = .recording
        kalman.reset()
        // 背景持續記錄需要「永遠允許」，僅在已取得使用中權限時再詢問一次
        if location.authorizationStatus == .authorizedWhenInUse {
            location.requestAlwaysPermission()
        }
        location.startUpdating(background: true)
        pedometer.start(from: startDate)
        altimeter.start()
        subscribe()
        startTimer()
        LiveActivityController.shared.start(mode: type, usesDistance: true)
        announcer.reset()
        if settings.keepScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
        CueService.shared.impact(.heavy)
        CueService.shared.speak("開始記錄")
    }

    func pause() {
        guard state == .recording else { return }
        commitSegment()
        pauseLog.append(Date())
        state = .paused
        updateLiveActivity(force: true)
        CueService.shared.impact(.light)
    }

    func resume() {
        guard state == .paused else { return }
        if pauseLog.count.isMultiple(of: 2) == false { pauseLog.append(Date()) }
        segmentStart = Date()
        state = .recording
        isAutoPaused = false
        updateLiveActivity(force: true)
        CueService.shared.impact(.light)
    }

    func stop() {
        commitSegment()
        state = .finished
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        location.stopUpdating()
        pedometer.stop()
        altimeter.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        // 用這次可信的 GPS 距離校正個人步幅，之後沒訊號時就靠它換算
        StrideCalibration.learn(distance: distance,
                                steps: pedometer.steps,
                                profile: workoutType.strideProfile)
        LiveActivityController.shared.end()
        CueService.shared.speak("記錄結束")
    }

    private func updateLiveActivity(force: Bool = false) {
        LiveActivityController.shared.update(elapsed: elapsed,
                                             distance: distance,
                                             steps: pedometer.steps,
                                             pace: currentPace ?? averagePace,
                                             statusText: isAutoPaused ? "自動暫停"
                                                : (state == .paused ? "已暫停" : "記錄中"),
                                             isPaused: state != .recording,
                                             force: force)
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        samples = []
        elapsed = 0
        distance = 0
        currentPace = nil
        averagePace = nil
        elevationGain = 0
        elevationLoss = 0
        currentSpeed = 0
        accumulated = 0
        segmentStart = nil
        pauseLog = []
        lastAccepted = nil
        lastAltitude = nil
        announcedKM = 0
        lowSpeedSince = nil
        isAutoPaused = false
        laps = []
        lastLapDistance = 0
        lastLapElapsed = 0
        state = .idle
    }

    // MARK: 內部

    private func subscribe() {
        location.locationSubject
            .sink { [weak self] loc in
                self?.ingest(loc)
            }
            .store(in: &cancellables)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard state == .recording, let segmentStart else { return }
        elapsed = accumulated + Date().timeIntervalSince(segmentStart)
        if distance > 10, elapsed > 0 {
            averagePace = elapsed / (distance / 1000)
        }
        updateLiveActivity()
        checkAutoPause()
    }

    private func commitSegment() {
        if let segmentStart {
            accumulated += Date().timeIntervalSince(segmentStart)
        }
        segmentStart = nil
        elapsed = accumulated
    }

    private func checkAutoPause() {
        guard settings.autoPause, state == .recording else { return }
        if currentSpeed < 0.45 {
            if let since = lowSpeedSince {
                if Date().timeIntervalSince(since) > 18 {
                    isAutoPaused = true
                    pause()
                }
            } else {
                lowSpeedSince = Date()
            }
        } else {
            lowSpeedSince = nil
        }
    }

    private func ingest(_ raw: CLLocation) {
        guard state == .recording || (state == .paused && isAutoPaused) else { return }
        guard raw.horizontalAccuracy > 0, raw.horizontalAccuracy < 45 else { return }

        let smoothed = kalman.process(latitude: raw.coordinate.latitude,
                                      longitude: raw.coordinate.longitude,
                                      altitude: raw.altitude,
                                      accuracy: raw.horizontalAccuracy,
                                      timestamp: raw.timestamp.timeIntervalSince1970)

        let coord = CLLocationCoordinate2D(latitude: smoothed.latitude, longitude: smoothed.longitude)
        currentSpeed = max(0, raw.speed)
        currentAltitude = smoothed.altitude
        location.applyPowerProfile(speed: currentSpeed)

        // 自動暫停狀態下偵測到移動 → 自動恢復
        if isAutoPaused, currentSpeed > 1.1 {
            isAutoPaused = false
            lowSpeedSince = nil
            resume()
        }
        guard state == .recording else { return }

        var delta = 0.0
        if let last = lastAccepted {
            delta = GeoMath.haversine(last.coordinate, coord)
            // 過濾靜止時的 GPS 漂移
            guard delta > 1.2 else { return }
            heading = GeoMath.bearing(from: last.coordinate, to: coord)
        }
        distance += delta

        if let lastAlt = lastAltitude {
            let diff = smoothed.altitude - lastAlt
            if diff > 0.8 { elevationGain += diff; lastAltitude = smoothed.altitude }
            else if diff < -0.8 { elevationLoss += -diff; lastAltitude = smoothed.altitude }
        } else {
            lastAltitude = smoothed.altitude
        }

        let sample = TrackSample(latitude: smoothed.latitude,
                                 longitude: smoothed.longitude,
                                 altitude: smoothed.altitude,
                                 timestamp: raw.timestamp,
                                 speed: windowSpeed(newCoordinate: coord, at: raw.timestamp),
                                 distanceFromStart: distance)
        samples.append(sample)
        lastAccepted = sample
        currentPace = GeoMath.pace(fromSpeed: sample.speed)
        announceIfNeeded()
    }

    /// 滑動窗口速度，避免 GPS 漂移造成配速亂跳
    private func windowSpeed(newCoordinate: CLLocationCoordinate2D, at time: Date) -> Double {
        let cutoff = time.addingTimeInterval(-paceWindow)
        let window = samples.filter { $0.timestamp >= cutoff }
        guard let first = window.first else { return currentSpeed }
        let dt = time.timeIntervalSince(first.timestamp)
        guard dt > 3 else { return currentSpeed }
        let dd = distance - first.distanceFromStart
        return max(0, dd / dt)
    }

    private func recordAutoLapIfNeeded() {
        guard autoLapDistance > 0 else { return }
        while distance - lastLapDistance >= autoLapDistance {
            let lapDuration = elapsed - lastLapElapsed
            lastLapDistance += autoLapDistance
            lastLapElapsed = elapsed
            laps.append(LapDraft(number: laps.count + 1,
                                 duration: lapDuration,
                                 distance: autoLapDistance,
                                 timestamp: Date()))
        }
    }

    private func announceIfNeeded() {
        recordAutoLapIfNeeded()
        announcer.announceIfNeeded(distance: distance,
                                   elapsed: elapsed,
                                   averagePace: averagePace,
                                   currentPace: currentPace,
                                   pacerDelta: timeLead)
    }

    // MARK: 輸出

    var coordinates: [CLLocationCoordinate2D] {
        samples.map { $0.coordinate }
    }

    // MARK: 虛擬配速員

    /// 依目標配速，此刻「應該」已跑的距離（公尺）
    var targetDistance: Double? {
        guard let targetPace, targetPace > 0, elapsed > 0 else { return nil }
        return elapsed / targetPace * 1000
    }

    /// 正值代表領先目標的公尺數，負值代表落後
    var paceLead: Double? {
        guard let targetDistance else { return nil }
        return distance - targetDistance
    }

    /// 正值代表領先的秒數，負值代表落後
    var timeLead: Double? {
        guard let targetPace, targetPace > 0, let lead = paceLead else { return nil }
        return lead / 1000 * targetPace
    }

    // MARK: 返回起點

    var startCoordinate: CLLocationCoordinate2D? {
        samples.first?.coordinate
    }

    /// 目前位置到起點的直線距離（公尺）
    var distanceToStart: Double? {
        guard let start = startCoordinate, let current = samples.last?.coordinate else { return nil }
        return GeoMath.haversine(current, start)
    }

    /// 回起點的方位角（度）
    var bearingToStart: Double? {
        guard let start = startCoordinate, let current = samples.last?.coordinate else { return nil }
        return GeoMath.bearing(from: current, to: start)
    }

    /// 存進 SwiftData 的完整場次
    func buildSession(weatherNote: String?, temperature: Double?) -> WorkoutSession {
        let end = Date()
        // 騎車、游泳這類運動，計步器數出來的是震動雜訊，不該當成步數
        let footBased: Bool = {
            guard let sport else { return true }
            switch SportCatalog.healthKitType(for: sport) {
            case .walking, .running, .hiking: return true
            default: return false
            }
        }()
        let session = WorkoutSession(type: workoutType,
                                     startDate: startDate,
                                     endDate: end,
                                     duration: elapsed,
                                     totalDistance: distance,
                                     averagePace: distance > 50 ? elapsed / (distance / 1000) : nil,
                                     elevationGain: elevationGain,
                                     elevationLoss: elevationLoss,
                                     stepCount: footBased && pedometer.steps > 0 ? pedometer.steps : nil,
                                     cadence: footBased && pedometer.cadence > 0 ? pedometer.cadence : nil,
                                     floorsAscended: footBased ? pedometer.floorsAscended : nil,
                                     floorsDescended: footBased ? pedometer.floorsDescended : nil,
                                     strideLength: footBased && pedometer.steps > 400 && distance > 300
                                        ? distance / Double(pedometer.steps) : nil,
                                     distanceSource: .gps,
                                     routeKey: routeKey.isEmpty ? nil : routeKey,
                                     title: sport?.name,
                                     notes: nil)
        session.sport = sport
        if let sport {
            session.calories = IntensityCalculator.calories(met: sport.met,
                                                            duration: elapsed,
                                                            bodyWeight: settings.bodyWeight)
            session.intensityScore = IntensityCalculator.score(met: sport.met,
                                                               duration: elapsed,
                                                               distance: distance,
                                                               averagePace: session.averagePace,
                                                               elevationGain: elevationGain)
        } else {
            session.calories = IntensityCalculator.calories(type: workoutType,
                                                            duration: elapsed,
                                                            bodyWeight: settings.bodyWeight)
            session.intensityScore = IntensityCalculator.score(type: workoutType,
                                                               duration: elapsed,
                                                               distance: distance,
                                                               averagePace: session.averagePace,
                                                               elevationGain: elevationGain)
        }
        session.weatherNote = weatherNote
        session.temperature = temperature
        session.pauseLog = pauseLog.isEmpty ? nil : pauseLog
        session.laps = laps.map {
            LapRecord(lapNumber: $0.number,
                      lapDuration: $0.duration,
                      distanceOverride: $0.distance,
                      timestamp: $0.timestamp)
        }
        session.routePoints = samples.map {
            RoutePoint(latitude: $0.latitude,
                       longitude: $0.longitude,
                       altitude: $0.altitude,
                       timestamp: $0.timestamp,
                       speed: $0.speed,
                       distanceFromStart: $0.distanceFromStart)
        }
        return session
    }
}
