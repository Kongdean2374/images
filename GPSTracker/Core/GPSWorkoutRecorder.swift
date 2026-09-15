import Foundation
import CoreLocation
import Combine
import SwiftUI

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
    @Published var routeKey: String = ""

    var startDate: Date = Date()

    private let location = LocationManager.shared
    private let settings = AppSettings.shared
    private let kalman = GPSKalmanFilter()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var lastAccepted: TrackSample?
    private var lastAltitude: Double?
    private var announcedKM = 0
    private var lowSpeedSince: Date?

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
        subscribe()
        startTimer()
        CueService.shared.impact(.heavy)
        CueService.shared.speak("開始記錄")
    }

    func pause() {
        guard state == .recording else { return }
        commitSegment()
        state = .paused
        CueService.shared.impact(.light)
    }

    func resume() {
        guard state == .paused else { return }
        segmentStart = Date()
        state = .recording
        isAutoPaused = false
        CueService.shared.impact(.light)
    }

    func stop() {
        commitSegment()
        state = .finished
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        location.stopUpdating()
        CueService.shared.speak("記錄結束")
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
        lastAccepted = nil
        lastAltitude = nil
        announcedKM = 0
        lowSpeedSince = nil
        isAutoPaused = false
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
        announceKMIfNeeded()
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

    private func announceKMIfNeeded() {
        let km = Int(distance / 1000)
        guard km > announcedKM else { return }
        announcedKM = km
        let paceText = Fmt.pace(averagePace)
        CueService.shared.speak("已完成 \(km) 公里，平均配速 \(paceText.replacingOccurrences(of: "'", with: "分").replacingOccurrences(of: "\"", with: "秒"))")
        CueService.shared.impact(.medium)
    }

    // MARK: 輸出

    var coordinates: [CLLocationCoordinate2D] {
        samples.map { $0.coordinate }
    }

    /// 存進 SwiftData 的完整場次
    func buildSession(weatherNote: String?, temperature: Double?) -> WorkoutSession {
        let end = Date()
        let session = WorkoutSession(type: workoutType,
                                     startDate: startDate,
                                     endDate: end,
                                     duration: elapsed,
                                     totalDistance: distance,
                                     averagePace: distance > 50 ? elapsed / (distance / 1000) : nil,
                                     elevationGain: elevationGain,
                                     elevationLoss: elevationLoss,
                                     routeKey: routeKey.isEmpty ? nil : routeKey,
                                     notes: nil)
        session.calories = IntensityCalculator.calories(type: workoutType,
                                                        duration: elapsed,
                                                        bodyWeight: settings.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: workoutType,
                                                           duration: elapsed,
                                                           distance: distance,
                                                           averagePace: session.averagePace,
                                                           elevationGain: elevationGain)
        session.weatherNote = weatherNote
        session.temperature = temperature
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
