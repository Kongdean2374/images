import Foundation
import CoreLocation

/// 從 GPX / TCX 檔案匯入一次運動（其他手錶或 App 匯出的檔案都能吃）
enum RouteFileImporter {

    struct ParsedRoute {
        var name: String?
        var startDate: Date?
        var points: [(coordinate: CLLocationCoordinate2D, altitude: Double, time: Date?)] = []
        var totalDistanceMeters: Double?
        var totalSeconds: TimeInterval?
        var calories: Double?
        var sport: String?
    }

    enum ImportError: LocalizedError {
        case unreadable
        case unsupported
        case noPoints

        var errorDescription: String? {
            switch self {
            case .unreadable: return "檔案無法讀取"
            case .unsupported: return "只支援 GPX 與 TCX 檔案"
            case .noPoints: return "檔案裡沒有可用的軌跡點或時間資料"
            }
        }
    }

    static func parse(url: URL) throws -> ParsedRoute {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let ext = url.pathExtension.lowercased()
        let parser = RouteXMLParser()
        guard let route = parser.parse(data: data, isTCX: ext == "tcx") else { throw ImportError.unreadable }
        guard !route.points.isEmpty || route.totalDistanceMeters != nil else { throw ImportError.noPoints }
        return route
    }

    /// 轉成 App 的紀錄
    @MainActor
    static func makeSession(from route: ParsedRoute, fileName: String) -> WorkoutSession? {
        let timedPoints = route.points.filter { $0.time != nil }
        let start = route.startDate ?? timedPoints.first?.time ?? Date()

        var accumulated = 0.0
        var previous: CLLocation?
        var points: [RoutePoint] = []
        var gain = 0.0
        var loss = 0.0

        for item in route.points {
            let location = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
            if let previous {
                accumulated += location.distance(from: previous)
            }
            if let last = points.last {
                let delta = item.altitude - last.altitude
                if delta > 0.8 { gain += delta } else if delta < -0.8 { loss += -delta }
            }
            points.append(RoutePoint(latitude: item.coordinate.latitude,
                                     longitude: item.coordinate.longitude,
                                     altitude: item.altitude,
                                     timestamp: item.time ?? start,
                                     speed: 0,
                                     distanceFromStart: accumulated))
            previous = location
        }

        let distance = route.totalDistanceMeters ?? (accumulated > 0 ? accumulated : nil)
        let duration: TimeInterval = {
            if let seconds = route.totalSeconds, seconds > 0 { return seconds }
            if let first = timedPoints.first?.time, let last = timedPoints.last?.time {
                return max(1, last.timeIntervalSince(first))
            }
            return 0
        }()
        guard duration > 0 else { return nil }

        let type: WorkoutType = {
            guard let sport = route.sport?.lowercased() else { return points.count > 1 ? .gpsRun : .manualEntry }
            if sport.contains("walk") || sport.contains("hike") { return .gpsHike }
            if sport.contains("run") { return .gpsRun }
            return points.count > 1 ? .gpsRun : .manualEntry
        }()

        let pace: Double? = {
            guard let distance, distance > 100 else { return nil }
            return duration / (distance / 1000)
        }()

        let session = WorkoutSession(type: type,
                                     startDate: start,
                                     endDate: start.addingTimeInterval(duration),
                                     duration: duration,
                                     totalDistance: distance,
                                     averagePace: pace,
                                     elevationGain: points.count > 1 ? gain : nil,
                                     elevationLoss: points.count > 1 ? loss : nil,
                                     distanceSource: points.count > 1 ? .gps : .manual,
                                     title: route.name ?? fileName)
        session.calories = route.calories ?? IntensityCalculator.calories(type: type,
                                                                          duration: duration,
                                                                          bodyWeight: AppSettings.shared.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: type,
                                                           duration: duration,
                                                           distance: distance,
                                                           averagePace: pace,
                                                           elevationGain: points.count > 1 ? gain : nil)
        session.isImported = true
        session.sourceApp = "檔案匯入"
        session.notes = "自 \(fileName) 匯入"
        session.routePoints = points
        return session
    }
}

/// GPX 與 TCX 的共用解析器
private final class RouteXMLParser: NSObject, XMLParserDelegate {
    private var route = RouteFileImporter.ParsedRoute()
    private var isTCX = false

    private var currentElement = ""
    private var currentText = ""
    private var pendingLatitude: Double?
    private var pendingLongitude: Double?
    private var pendingAltitude: Double = 0
    private var pendingTime: Date?
    private var insideTrackpoint = false

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(data: Data, isTCX: Bool) -> RouteFileImporter.ParsedRoute? {
        self.isTCX = isTCX
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return route.points.isEmpty ? nil : route }
        return route
    }

    private func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isoWithFraction.date(from: trimmed) ?? Self.iso.date(from: trimmed)
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "trkpt", "wpt":
            insideTrackpoint = true
            pendingLatitude = Double(attributeDict["lat"] ?? "")
            pendingLongitude = Double(attributeDict["lon"] ?? "")
            pendingAltitude = 0
            pendingTime = nil
        case "Trackpoint":
            insideTrackpoint = true
            pendingLatitude = nil
            pendingLongitude = nil
            pendingAltitude = 0
            pendingTime = nil
        case "Activity":
            route.sport = attributeDict["Sport"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            if route.name == nil, !text.isEmpty { route.name = text }
        case "ele", "AltitudeMeters":
            pendingAltitude = Double(text) ?? pendingAltitude
        case "time", "Time":
            let date = parseDate(text)
            if insideTrackpoint {
                pendingTime = date
            } else if route.startDate == nil {
                route.startDate = date
            }
        case "LatitudeDegrees":
            pendingLatitude = Double(text)
        case "LongitudeDegrees":
            pendingLongitude = Double(text)
        case "DistanceMeters":
            // TCX 的 Lap 與 Trackpoint 都有這個欄位，取最大值當總距離
            if let value = Double(text), !insideTrackpoint {
                route.totalDistanceMeters = max(route.totalDistanceMeters ?? 0, value)
            }
        case "TotalTimeSeconds":
            if let value = Double(text) {
                route.totalSeconds = (route.totalSeconds ?? 0) + value
            }
        case "Calories":
            if let value = Double(text) {
                route.calories = (route.calories ?? 0) + value
            }
        case "Id":
            if route.startDate == nil { route.startDate = parseDate(text) }
        case "trkpt", "wpt", "Trackpoint":
            if let lat = pendingLatitude, let lon = pendingLongitude {
                route.points.append((CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                     pendingAltitude,
                                     pendingTime))
            }
            insideTrackpoint = false
        default:
            break
        }
        currentText = ""
    }
}
