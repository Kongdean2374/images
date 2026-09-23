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
    /// 判斷自動暫停時用的參考點：一段時間內位置沒有真的移動才算停下來
    private var autoPauseAnchor: (coordinate: CLLocationCoordinate2D, date: Date)?
    /// 最近一次拿到的有效衛星速度（CoreLocation 給 -1 代表沒有值）
    private var lastValidSpeed: Double = 0

    // MARK: 輔助模式（定位失效時自動改用推估）

    /// 目前是不是靠推估在記錄
    @Published private(set) var isAssisted = false
    /// 目前這段空白的原因
    @Published private(set) var assistReason: CoverageGap.Reason = .noSignal
    /// 已經完成的空白區段
    @Published private(set) var coverageGaps: [CoverageGap] = []

    /// 最近一次收到「可用」座標的時間
    private var lastGoodFix: Date?
    /// 精度連續不佳的起始時間
    private var poorAccuracySince: Date?
    /// 目前這段空白的起點
    private var currentGapStart: (date: Date, distance: Double, steps: Int)?
    /// 進入輔助模式時的計步基準
    private var assistStepBaseline: Int = 0
    /// 推估用的步幅
    private var assistStride: Double = 0
    /// 推估距離的累計，離開輔助模式時併入總距離
    private var assistDistance: Double = 0
    /// 上次推估的時間點（非計步型運動用最後速度推算時會用到）
    private var lastAssistTick: Date?
    /// 剛離開輔助模式，下一個座標要當成新起點而不是接續
    private var justResumedFromGap = false

    // MARK: 診斷計數（讓收訊問題可以被看見，不用猜）
    @Published private(set) var received = 0
    @Published private(set) var rejectedAccuracy = 0
    @Published private(set) var rejectedStale = 0
    @Published private(set) var rejectedDrift = 0
    @Published private(set) var rejectedJump = 0
    var accepted: Int { samples.count }

    /// 完全沒有可用座標超過這麼久才進入輔助模式。
    /// 判斷依據是「有沒有真的收進軌跡的點」，不是原始精度數字——
    /// 精度 40 公尺照樣可以是有用的點，不該因此停止記錄。
    private let noSignalTimeout: TimeInterval = 25
    /// 精度爛到連放寬後的閘門都收不下，才算失效
    private let poorAccuracyLimit: Double = 75
    private let poorAccuracyTimeout: TimeInterval = 30
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
        autosave(force: true)
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
        // 注意：這裡「不」清除自動存檔。
        // 必須等 SessionSaver 確認寫進資料庫成功之後才清，
        // 否則資料庫儲存失敗時兩份都沒了。
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
        autoPauseAnchor = nil
        lastValidSpeed = 0
        isAssisted = false
        coverageGaps = []
        currentGapStart = nil
        lastGoodFix = nil
        poorAccuracySince = nil
        assistDistance = 0
        justResumedFromGap = false
        received = 0
        rejectedAccuracy = 0
        rejectedStale = 0
        rejectedDrift = 0
        rejectedJump = 0
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
        updateAssistedTracking()
        updateLiveActivity()
        checkAutoPause()
        autosave()
    }

    /// 每收到一次座標就更新訊號品質，作為自動切換的依據。
    /// 只有「爛到連放寬後的閘門都收不下」才開始計時，避免在開闊地誤判。
    private func noteSignalQuality(of raw: CLLocation) {
        let accuracy = raw.horizontalAccuracy
        guard accuracy > 0 else { return }

        if accuracy <= poorAccuracyLimit {
            poorAccuracySince = nil
        } else if poorAccuracySince == nil {
            poorAccuracySince = Date()
        }
    }

    // MARK: 輔助模式切換

    /// 每個計時週期檢查一次定位還可不可信，必要時自動切換。
    private func updateAssistedTracking() {
        guard settings.assistedTracking, state == .recording else {
            if isAssisted { endGap() }
            return
        }

        let now = Date()
        let silence = lastGoodFix.map { now.timeIntervalSince($0) } ?? now.timeIntervalSince(startDate)
        let poorFor = poorAccuracySince.map { now.timeIntervalSince($0) } ?? 0

        if isAssisted {
            accumulateAssistedDistance(at: now)
            // 恢復條件：剛剛收到夠準的座標
            if silence < 3 { endGap() }
            return
        }

        if silence > noSignalTimeout {
            beginGap(reason: .noSignal, at: now)
        } else if poorFor > poorAccuracyTimeout {
            beginGap(reason: .poorAccuracy, at: now)
        }
    }

    private func beginGap(reason: CoverageGap.Reason, at date: Date) {
        guard !isAssisted else { return }
        isAssisted = true
        assistReason = reason
        assistStepBaseline = pedometer.steps
        assistDistance = 0
        lastAssistTick = date
        assistStride = StrideCalibration.stride(workoutType.strideProfile)
        currentGapStart = (date, distance, pedometer.steps)
        CueService.shared.impact(.light)
        if settings.voiceCues {
            let how = usesSteps ? "改用計步記錄" : "這段不計距離"
            CueService.shared.speak(reason == .noSignal ? "定位中斷，\(how)" : "定位精度不佳，\(how)")
        }
    }

    /// 輔助期間補距離。
    ///
    /// 只有「腳實際走出來」的運動（走路、跑步、健行）才用計步 × 步幅推估，
    /// 這種推估有實際依據。騎車、划船這類沒有步數的運動則**完全不補距離**：
    /// 時間照跑、空白段照記，但距離停在中斷前的數字。
    /// 寧可少算，也不要憑空生出一個錯的數字讓整筆紀錄失真。
    private func accumulateAssistedDistance(at date: Date) {
        defer { lastAssistTick = date }
        guard usesSteps else { return }
        guard let last = lastAssistTick else { return }
        let dt = date.timeIntervalSince(last)
        guard dt > 0, dt < 5 else { return }

        // 以計步增量 × 個人步幅推估
        let newSteps = max(0, pedometer.steps - assistStepBaseline)
        let estimated = Double(newSteps) * assistStride
        let increment = max(0, estimated - assistDistance)
        assistDistance = estimated
        distance += increment
    }

    /// 這個運動用計步推估距離才有意義。
    /// 不成立的話，空白段就只記時間，不碰距離。
    private var usesSteps: Bool {
        guard let sport else { return workoutType.isStepBased || workoutType == .gpsRun || workoutType == .gpsHike }
        switch SportCatalog.healthKitType(for: sport) {
        case .walking, .running, .hiking: return true
        default: return false
        }
    }

    private func endGap() {
        guard isAssisted, let start = currentGapStart else {
            isAssisted = false
            currentGapStart = nil
            return
        }
        let now = Date()
        isAssisted = false
        currentGapStart = nil
        lastAssistTick = nil

        // 太短的中斷不留紀錄，免得一堆兩秒的空白
        guard now.timeIntervalSince(start.date) >= 8 else { return }

        let gap = CoverageGap(start: start.date,
                              end: now,
                              startDistance: start.distance,
                              endDistance: distance,
                              steps: usesSteps ? max(0, pedometer.steps - start.steps) : nil,
                              sourceRaw: (usesSteps ? DistanceSource.stride : DistanceSource.gps).rawValue,
                              reasonRaw: assistReason.rawValue)
        coverageGaps.append(gap)
        justResumedFromGap = true
        CueService.shared.impact(.medium)
        if settings.voiceCues { CueService.shared.speak("定位已恢復") }
    }

    private func commitSegment() {
        if let segmentStart {
            accumulated += Date().timeIntervalSince(segmentStart)
        }
        segmentStart = nil
        elapsed = accumulated
    }

    /// 自動暫停判斷。
    ///
    /// 以前只看 `currentSpeed`，但 CoreLocation 在訊號不佳時會回傳 speed = -1，
    /// 被當成 0 之後就會在騎車途中誤判成停下來。現在改成必須「速度低」
    /// **而且**「這段時間內位置幾乎沒移動」兩個條件同時成立才暫停。
    private func checkAutoPause() {
        guard settings.autoPause, state == .recording else { return }
        guard let current = lastAccepted else { return }
        let now = Date()
        let position = CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude)

        guard let anchor = autoPauseAnchor else {
            autoPauseAnchor = (position, now)
            return
        }

        let moved = GeoMath.haversine(anchor.coordinate, position)
        let waited = now.timeIntervalSince(anchor.date)

        // 只要有明顯位移就重新起算，不可能是停著
        if moved > 12 {
            autoPauseAnchor = (position, now)
            lowSpeedSince = nil
            return
        }

        // 位移很小，再看速度。速度無效（-1）時只信位移。
        if lastValidSpeed >= 0.8 {
            autoPauseAnchor = (position, now)
            lowSpeedSince = nil
            return
        }

        // 原地超過 25 秒才判定停下來
        if waited > 25 {
            isAutoPaused = true
            pause()
            autoPauseAnchor = nil
        }
    }

    private func ingest(_ raw: CLLocation) {
        guard state == .recording || (state == .paused && isAutoPaused) else { return }

        // 先記錄訊號品質，輔助模式靠這個判斷要不要接手
        noteSignalQuality(of: raw)

        received += 1

        // 精度閘門。
        //
        // 上一版寫死 25 公尺太嚴：螢幕關閉時 iOS 會降低 GPS 取樣功率，
        // 即使在開闊地回報的誤差也常落在 25–40 公尺，結果整批座標被丟掉，
        // 軌跡就變成兩點之間的一條直線。
        // 改成基準 35 公尺，而且愈久沒收到可用座標就愈放寬，最多到 70 公尺，
        // 寧可先收下再靠後面的跳點與漂移檢查把壞點濾掉，也不要整段變空白。
        let starvedFor = lastAccepted.map { Date().timeIntervalSince($0.timestamp) } ?? 0
        let accuracyLimit: Double = min(70, 35 + max(0, starvedFor - 10) * 2)
        guard raw.horizontalAccuracy > 0, raw.horizontalAccuracy <= accuracyLimit else {
            rejectedAccuracy += 1
            return
        }

        // 時間檢查。
        //
        // 原本丟掉「超過 30 秒前」的座標，但 iOS 在背景會把更新批次化，
        // 一次送來一串時間較早的點——那正是我們最需要的資料。
        // 改成只要比「已接受的最後一點」新就收下。
        if let last = lastAccepted, raw.timestamp <= last.timestamp {
            rejectedStale += 1
            return
        }

        // 速度：-1 代表系統無法判定，這時不要當成 0
        if raw.speed >= 0 {
            lastValidSpeed = raw.speed
            currentSpeed = raw.speed
        }

        let smoothed = kalman.process(latitude: raw.coordinate.latitude,
                                      longitude: raw.coordinate.longitude,
                                      altitude: raw.altitude,
                                      accuracy: raw.horizontalAccuracy,
                                      timestamp: raw.timestamp.timeIntervalSince1970)

        let coord = CLLocationCoordinate2D(latitude: smoothed.latitude, longitude: smoothed.longitude)
        currentAltitude = smoothed.altitude
        location.applyPowerProfile(speed: max(currentSpeed, lastValidSpeed))

        // 自動暫停狀態下偵測到移動 → 自動恢復
        if isAutoPaused {
            let movedEnough: Bool
            if let last = lastAccepted {
                movedEnough = GeoMath.haversine(last.coordinate, coord) > 10
            } else {
                movedEnough = false
            }
            if lastValidSpeed > 1.1 || movedEnough {
                isAutoPaused = false
                lowSpeedSince = nil
                autoPauseAnchor = nil
                resume()
            }
        }
        guard state == .recording else { return }

        var delta = 0.0
        // 剛從空白段恢復：距離已經由推估補過了，這一點不再重複累加，
        // 只把它當成新的起點，地圖上就會留下一段空白
        if justResumedFromGap {
            justResumedFromGap = false
            lastAccepted = TrackSample(latitude: smoothed.latitude,
                                       longitude: smoothed.longitude,
                                       altitude: smoothed.altitude,
                                       timestamp: raw.timestamp,
                                       speed: max(0, currentSpeed),
                                       distanceFromStart: distance)
            samples.append(lastAccepted!)
            lastGoodFix = Date()
            lastAltitude = smoothed.altitude
            currentPace = GeoMath.pace(fromSpeed: currentSpeed)
            return
        }

        if let last = lastAccepted {
            delta = GeoMath.haversine(last.coordinate, coord)
            let dt = raw.timestamp.timeIntervalSince(last.timestamp)

            // 合理性檢查：算出來的速度超過 40 m/s（144 km/h）一定是跳點
            if dt > 0.3, delta / dt > 40 {
                rejectedJump += 1
                return
            }

            // 漂移門檻。
            //
            // 原本是「誤差 × 0.55」，在誤差 25 公尺時等於要移動 13.7 公尺才收，
            // 騎車一秒才移動 5 公尺，等於幾乎每個點都被丟掉。
            // 改成先看「照速度推算應該移動多少」：確定在動就用很小的門檻，
            // 只有靜止時才用誤差推算的門檻，而且上限壓在 8 公尺。
            let expected = max(lastValidSpeed, 0) * max(0, dt)
            let driftFloor: Double
            if expected > 3 || lastValidSpeed > 1.0 {
                driftFloor = 1.5          // 明顯在移動
            } else {
                driftFloor = min(8, max(2.5, raw.horizontalAccuracy * 0.35))
            }
            guard delta > driftFloor else {
                rejectedDrift += 1
                return
            }

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
        lastGoodFix = Date()
        currentPace = GeoMath.pace(fromSpeed: sample.speed)
        announceIfNeeded()
    }

    // MARK: 自動存檔與回復

    /// 目前狀態的快照，供自動存檔用
    var snapshot: ActiveWorkoutSnapshot {
        ActiveWorkoutSnapshot(typeRaw: workoutType.rawValue,
                              sportID: sport?.id,
                              startDate: startDate,
                              savedAt: Date(),
                              elapsed: elapsed,
                              distance: distance,
                              elevationGain: elevationGain,
                              elevationLoss: elevationLoss,
                              routeKey: routeKey,
                              targetPace: targetPace,
                              autoLapDistance: autoLapDistance,
                              pauseLog: pauseLog,
                              points: samples.map {
                                  ActiveWorkoutSnapshot.Point(lat: $0.latitude,
                                                              lon: $0.longitude,
                                                              alt: $0.altitude,
                                                              time: $0.timestamp,
                                                              speed: $0.speed,
                                                              distance: $0.distanceFromStart)
                              },
                              laps: laps.map {
                                  ActiveWorkoutSnapshot.Lap(number: $0.number,
                                                            duration: $0.duration,
                                                            distance: $0.distance,
                                                            timestamp: $0.timestamp)
                              },
                              gaps: coverageGaps)
    }

    /// 把目前進度寫到磁碟。force 用在暫停、進背景這種關鍵時刻。
    ///
    /// 先問節流器要不要寫，確定要寫才組快照——組快照要走訪全部軌跡點，
    /// 每 0.2 秒都組一次的話，長距離運動會把 CPU 吃光。
    func autosave(force: Bool = false) {
        guard state == .recording || state == .paused else { return }
        guard ActiveWorkoutStore.shared.shouldWrite(force: force) else { return }
        ActiveWorkoutStore.shared.save(snapshot, force: true)
    }

    /// 從中斷的自動存檔接續記錄
    func restore(from snapshot: ActiveWorkoutSnapshot) {
        reset()
        workoutType = snapshot.type
        sport = snapshot.sport
        startDate = snapshot.startDate
        routeKey = snapshot.routeKey
        targetPace = snapshot.targetPace
        autoLapDistance = snapshot.autoLapDistance
        pauseLog = snapshot.pauseLog
        coverageGaps = snapshot.gaps ?? []
        accumulated = snapshot.elapsed
        elapsed = snapshot.elapsed
        distance = snapshot.distance
        elevationGain = snapshot.elevationGain
        elevationLoss = snapshot.elevationLoss
        lastLapDistance = snapshot.autoLapDistance > 0
            ? (snapshot.distance / snapshot.autoLapDistance).rounded(.down) * snapshot.autoLapDistance
            : 0
        lastLapElapsed = snapshot.elapsed

        samples = snapshot.points.map {
            TrackSample(latitude: $0.lat,
                        longitude: $0.lon,
                        altitude: $0.alt,
                        timestamp: $0.time,
                        speed: $0.speed,
                        distanceFromStart: $0.distance)
        }
        laps = snapshot.laps.map {
            LapDraft(number: $0.number,
                     duration: $0.duration,
                     distance: $0.distance,
                     timestamp: $0.timestamp)
        }
        lastAccepted = samples.last
        lastAltitude = samples.last?.altitude

        // 接著繼續錄
        segmentStart = Date()
        state = .recording
        kalman.reset()
        location.startUpdating(background: true)
        pedometer.start(from: Date())
        altimeter.start()
        subscribe()
        startTimer()
        LiveActivityController.shared.start(mode: workoutType, usesDistance: true)
        announcer.reset()
        if settings.keepScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
        CueService.shared.speak("已接續先前的運動")
    }

    /// 滑動窗口速度，避免 GPS 漂移造成配速亂跳
    private func windowSpeed(newCoordinate: CLLocationCoordinate2D, at time: Date) -> Double {
        // 從尾端往回走到超出時間窗就停。原本用 filter 掃整個陣列，
        // 長距離運動累積到上萬點時，每收到一個座標就要掃一次。
        let cutoff = time.addingTimeInterval(-paceWindow)
        var index = samples.count - 1
        var first: TrackSample?
        while index >= 0 {
            let sample = samples[index]
            if sample.timestamp < cutoff { break }
            first = sample
            index -= 1
        }
        guard let first else { return currentSpeed }
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
        session.coverageGaps = coverageGaps
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
