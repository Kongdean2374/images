import Foundation

/// GPX / TCX 匯出：不需要 HealthKit 權限，就能把紀錄帶進
/// Strava、Garmin Connect、Komoot 等 App。
enum RouteFileExporter {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func escape(_ text: String) -> String { ExportEncoding.xml(text) }

    // MARK: GPX

    static func gpx(for session: WorkoutSession) -> String? {
        let points = session.sortedPoints
        guard points.count > 1 else { return nil }

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<gpx version=\"1.1\" creator=\"GPS 軌跡記錄器\" xmlns=\"http://www.topografix.com/GPX/1/1\">")
        lines.append("  <metadata>")
        lines.append("    <name>\(escape(session.displayTitle))</name>")
        lines.append("    <time>\(iso.string(from: session.startDate))</time>")
        lines.append("  </metadata>")
        lines.append("  <trk>")
        lines.append("    <name>\(escape(session.displayTitle))</name>")
        lines.append("    <type>\(session.type.rawValue)</type>")
        lines.append("    <trkseg>")
        for point in points {
            lines.append(String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\">", point.latitude, point.longitude))
            lines.append(String(format: "        <ele>%.1f</ele>", point.altitude))
            lines.append("        <time>\(iso.string(from: point.timestamp))</time>")
            lines.append("      </trkpt>")
        }
        lines.append("    </trkseg>")
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }

    static func gpxFile(for session: WorkoutSession) -> URL? {
        guard let text = gpx(for: session) else { return nil }
        return DataExporter.write(text.data(using: .utf8),
                                  filename: "workout-\(DataExporter.stamp()).gpx")
    }

    // MARK: TCX

    /// TCX 比 GPX 多了時間、距離、熱量與分圈，無軌跡的場次也能匯出。
    static func tcx(for session: WorkoutSession) -> String {
        TCXEncoder.encode(TCXRecord(start: session.startDate, end: session.endDate, duration: session.duration,
            distance: session.totalDistance, calories: session.calories,
            running: [.treadmill, .gpsRun, .run, .lapCounter].contains(session.type),
            notes: (session.notes ?? session.displayTitle) + "；距離來源：" + session.evidence.method.label,
            points: session.sortedPoints.map { TCXRecord.Point(time: $0.timestamp, latitude: $0.latitude,
                longitude: $0.longitude, altitude: $0.altitude, distance: $0.distanceFromStart) }))
    }

    static func tcxFile(for session: WorkoutSession) -> URL? {
        DataExporter.write(tcx(for: session).data(using: .utf8),
                           filename: "workout-\(DataExporter.stamp()).tcx")
    }
}
