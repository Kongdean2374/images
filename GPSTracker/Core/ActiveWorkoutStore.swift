import Foundation
import CoreLocation

/// 進行中運動的自動存檔。
///
/// iOS 會在記憶體吃緊時直接終止背景 App，使用者也可能從多工手勢把它滑掉。
/// 只靠記憶體裡的狀態，整場運動就這樣沒了——所以每隔幾秒就把目前的進度
/// 寫到磁碟，下次啟動時再問使用者要繼續、要存成紀錄、還是丟掉。
struct ActiveWorkoutSnapshot: Codable, Identifiable, Sendable {
    var id: Date { startDate }

    struct Point: Codable, Sendable {
        let lat: Double
        let lon: Double
        let alt: Double
        let time: Date
        let speed: Double
        let distance: Double
        var accuracy: Double? = nil
    }

    struct Lap: Codable, Sendable {
        let number: Int
        let duration: TimeInterval
        let distance: Double
        let timestamp: Date
    }

    var typeRaw: String
    var sportID: String?
    var startDate: Date
    var savedAt: Date
    var elapsed: TimeInterval
    var distance: Double
    var elevationGain: Double
    var elevationLoss: Double
    var routeKey: String
    var targetPace: Double?
    var autoLapDistance: Double
    var pauseLog: [Date]
    var points: [Point]
    var laps: [Lap]
    /// 定位失效的空白段
    var gaps: [CoverageGap]?
    var sessionID: UUID? = nil
    var recoveredSessionID: UUID { sessionID ?? RecoveryIdentity.id(start: startDate, type: typeRaw) }

    var type: WorkoutType { WorkoutType(rawValue: typeRaw) ?? .gpsRun }
    var sport: SportKind? { SportCatalog.find(sportID) }

    /// 有沒有值得救回來的內容
    var isWorthRecovering: Bool {
        elapsed >= 60 || distance >= 100 || points.count >= 20
    }
}

final class ActiveWorkoutStore {
    static let shared = ActiveWorkoutStore()

    private static let fileName = "active-workout.json"
    private var lastWrite = Date.distantPast
    private let persistence: SnapshotPersistence<ActiveWorkoutSnapshot>?
    private init() {
        let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        persistence = directory.map { SnapshotPersistence(url: $0.appendingPathComponent(Self.fileName)) }
    }

    // MARK: 寫入

    /// 背景時拉長存檔間隔：組快照要走訪全部座標點，長距離運動這件事本身
    /// 就是可觀的 CPU 開銷，而背景 CPU 用量過高會讓 iOS 直接終止 App。
    var isInBackground = false

    /// 問節流器現在該不該寫。呼叫端先問過再組快照，省下無謂的走訪。
    func shouldWrite(force: Bool) -> Bool {
        let interval: TimeInterval = isInBackground ? 25 : 8
        return force || Date().timeIntervalSince(lastWrite) > interval
    }

    /// 節流寫入。`force` 用在暫停、進背景這種關鍵時刻，必定寫入。
    func save(_ snapshot: ActiveWorkoutSnapshot, force: Bool = false) {
        guard shouldWrite(force: force) else { return }
        lastWrite = Date()
        persistence?.save(snapshot)
    }

    // MARK: 讀取與清除

    func loadForRecovery() async -> SnapshotRead<ActiveWorkoutSnapshot> {
        guard let persistence else { return .unreadable }
        return await persistence.load()
    }

    func clear() {
        lastWrite = .distantPast
        persistence?.clear()
    }

    // MARK: 轉成正式紀錄

    /// 把自動存檔直接還原成一筆完成的運動紀錄
    static func buildSession(from snapshot: ActiveWorkoutSnapshot, bodyWeight: Double) -> WorkoutSession {
        let end = snapshot.points.last?.time ?? snapshot.savedAt
        let duration = max(snapshot.elapsed, 1)
        let distance = snapshot.distance

        let session = WorkoutSession(id: snapshot.recoveredSessionID, type: snapshot.type,
                                     startDate: snapshot.startDate,
                                     endDate: end,
                                     duration: duration,
                                     totalDistance: distance > 0 ? distance : nil,
                                     averagePace: distance > 50 ? duration / (distance / 1000) : nil,
                                     elevationGain: snapshot.elevationGain,
                                     elevationLoss: snapshot.elevationLoss,
                                     distanceSource: snapshot.gaps?.isEmpty == false ? .mixed : .unknown,
                                     routeKey: snapshot.routeKey.isEmpty ? nil : snapshot.routeKey,
                                     title: snapshot.sport?.name,
                                     notes: "從中斷的紀錄自動回復")
        session.sport = snapshot.sport
        session.pauseLog = snapshot.pauseLog.isEmpty ? nil : snapshot.pauseLog
        session.coverageGaps = snapshot.gaps ?? []

        let met = snapshot.sport?.met ?? snapshot.type.metValue
        session.calories = IntensityCalculator.calories(met: met,
                                                        duration: duration,
                                                        bodyWeight: bodyWeight)
        session.intensityScore = IntensityCalculator.score(met: met,
                                                           duration: duration,
                                                           distance: distance,
                                                           averagePace: session.averagePace,
                                                           elevationGain: snapshot.elevationGain)
        session.laps = snapshot.laps.map {
            LapRecord(lapNumber: $0.number,
                      lapDuration: $0.duration,
                      distanceOverride: $0.distance,
                      timestamp: $0.timestamp)
        }
        session.routePoints = snapshot.points.map {
            RoutePoint(latitude: $0.lat,
                       longitude: $0.lon,
                       altitude: $0.alt,
                       timestamp: $0.time,
                       speed: $0.speed,
                       distanceFromStart: $0.distance,
                       horizontalAccuracy: $0.accuracy)
        }
        return session
    }
}
