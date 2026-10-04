import Foundation
import CoreLocation

/// 進行中運動的自動存檔。
///
/// iOS 會在記憶體吃緊時直接終止背景 App，使用者也可能從多工手勢把它滑掉。
/// 只靠記憶體裡的狀態，整場運動就這樣沒了——所以每隔幾秒就把目前的進度
/// 寫到磁碟，下次啟動時再問使用者要繼續、要存成紀錄、還是丟掉。
struct ActiveWorkoutSnapshot: Codable, Identifiable {
    var id: Date { startDate }

    struct Point: Codable {
        let lat: Double
        let lon: Double
        let alt: Double
        let time: Date
        let speed: Double
        let distance: Double
        var horizontalAccuracy: Double?
        var verticalAccuracy: Double?
        var course: Double?
        var rawSpeed: Double?
        var speedAccuracy: Double?
        var courseAccuracy: Double?
        var rawLatitude: Double?
        var rawLongitude: Double?
    }

    struct Lap: Codable {
        let number: Int
        let duration: TimeInterval
        let distance: Double
        let timestamp: Date
    }

    var pointOffset: Int?
    var disciplineID: String?
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

    var type: WorkoutType { WorkoutType(rawValue: typeRaw) ?? .gpsRun }
    var sport: SportKind? { SportCatalog.find(sportID) }

    /// 有沒有值得救回來的內容
    var isWorthRecovering: Bool {
        elapsed >= 60 || distance >= 100 || points.count >= 20
    }
}

final class ActiveWorkoutStore {
    static let shared = ActiveWorkoutStore()

    private let fileName = "active-workout.json"
    private var lastWrite = Date.distantPast
    /// 寫檔專用佇列：JSON 編碼上萬個座標點不能卡在主執行緒上
    private let queue = DispatchQueue(label: "com.gpstracker.activeworkout",
                                      qos: .utility)

    private var url: URL? {
        guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true) else { return nil }
        return directory.appendingPathComponent(fileName)
    }

    private init() {}

    // Accessed by the recorder on the main thread; I/O is ordered on queue.
    var isInBackground = false
    private(set) var savedPointCount = 0
    private var writing = false
    private var generation = UUID()
    private var sessionStart: Date?
    private var journalURL: URL? { url?.appendingPathExtension("journal") }

    func pointOffset(for start: Date) -> Int { sessionStart == start ? savedPointCount : 0 }

    func shouldWrite(force: Bool) -> Bool {
        !writing && (force || Date().timeIntervalSince(lastWrite) > (isInBackground ? 25 : 8))
    }

    /// Each durable line contains only new points and a metadata checkpoint.
    /// A crash mid-write leaves the previous complete line recoverable.
    func save(_ snapshot: ActiveWorkoutSnapshot, force: Bool = false) {
        guard shouldWrite(force: force), let journalURL else { return }
        let offset = snapshot.pointOffset ?? 0
        let reset = sessionStart != snapshot.startDate || offset == 0
        let ticket = generation
        writing = true
        queue.async {
            var succeeded = false
            do {
                let encoder = JSONEncoder() // preserves sub-second timestamps
                var data = try encoder.encode(snapshot)
                data.append(0x0A)
                if reset {
                    try data.write(to: journalURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: journalURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                }
                succeeded = true
            } catch { }
            let didSave = succeeded
            DispatchQueue.main.async {
                guard self.generation == ticket else { return }
                self.writing = false
                if didSave {
                    self.savedPointCount = offset + snapshot.points.count
                    self.sessionStart = snapshot.startDate
                    self.lastWrite = Date()
                }
            }
        }
    }

    func load() -> ActiveWorkoutSnapshot? {
        queue.sync {
            if let journalURL, let data = try? Data(contentsOf: journalURL) {
                var latest: ActiveWorkoutSnapshot?
                var points: [ActiveWorkoutSnapshot.Point] = []
                // Only newline-terminated records were committed.
                let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                for line in lines.dropLast() {
                    guard let delta = try? JSONDecoder().decode(ActiveWorkoutSnapshot.self, from: Data(line)) else { break }
                    let offset = delta.pointOffset ?? 0
                    if offset == 0 { points.removeAll(keepingCapacity: true) }
                    guard offset == points.count else { break }
                    points.append(contentsOf: delta.points)
                    latest = delta
                }
                if var latest {
                    latest.points = points
                    latest.pointOffset = 0
                    return latest
                }
            }
            // Non-destructive compatibility with the previous full JSON snapshot.
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ActiveWorkoutSnapshot.self, from: data)
        }
    }

    var hasPending: Bool { load()?.isWorthRecovering ?? false }

    func clear() {
        generation = UUID()
        writing = false
        savedPointCount = 0
        sessionStart = nil
        lastWrite = .distantPast
        let legacy = url
        let journal = journalURL
        // Order deletion after pending writes so a late autosave cannot resurrect a finished workout.
        queue.async {
            if let legacy { try? FileManager.default.removeItem(at: legacy) }
            if let journal { try? FileManager.default.removeItem(at: journal) }
        }
    }

    // MARK: 轉成正式紀錄

    /// 把自動存檔直接還原成一筆完成的運動紀錄
    @MainActor
    func buildSession(from snapshot: ActiveWorkoutSnapshot) -> WorkoutSession {
        let end = snapshot.points.last?.time ?? snapshot.savedAt
        let duration = max(snapshot.elapsed, 1)
        let distance = snapshot.distance

        let session = WorkoutSession(type: snapshot.type,
                                     startDate: snapshot.startDate,
                                     endDate: end,
                                     duration: duration,
                                     totalDistance: distance > 0 ? distance : nil,
                                     averagePace: distance > 50 ? duration / (distance / 1000) : nil,
                                     elevationGain: snapshot.elevationGain,
                                     elevationLoss: snapshot.elevationLoss,
                                     distanceSource: distance > 0 ? .gps : nil,
                                     routeKey: snapshot.routeKey.isEmpty ? nil : snapshot.routeKey,
                                     title: snapshot.sport?.name,
                                     notes: "從中斷的紀錄自動回復")
        session.sport = snapshot.sport
        session.pauseLog = snapshot.pauseLog.isEmpty ? nil : snapshot.pauseLog
        session.coverageGaps = snapshot.gaps ?? []

        let met = snapshot.sport?.met ?? snapshot.type.metValue
        session.calories = IntensityCalculator.calories(met: met,
                                                        duration: duration,
                                                        bodyWeight: AppSettings.shared.bodyWeight)
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
                       horizontalAccuracy: $0.horizontalAccuracy,
                       verticalAccuracy: $0.verticalAccuracy,
                       course: $0.course,
                       rawSpeed: $0.rawSpeed,
                       speedAccuracy: $0.speedAccuracy,
                       courseAccuracy: $0.courseAccuracy,
                       rawLatitude: $0.rawLatitude,
                       rawLongitude: $0.rawLongitude)
        }
        return session
    }
}
