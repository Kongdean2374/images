import Foundation

/// GPX / TCX 匯出：不需要 HealthKit 權限，就能把紀錄帶進
/// Strava、Garmin Connect、Komoot 等 App。
enum RouteFileExporter {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

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
        let points = session.sortedPoints
        let sport: String
        switch session.type {
        case .walk, .gpsHike: sport = "Other"
        case .treadmill, .gpsRun, .run, .lapCounter: sport = "Running"
        default: sport = "Other"
        }

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">")
        lines.append("  <Activities>")
        lines.append("    <Activity Sport=\"\(sport)\">")
        lines.append("      <Id>\(iso.string(from: session.startDate))</Id>")
        lines.append("      <Lap StartTime=\"\(iso.string(from: session.startDate))\">")
        lines.append(String(format: "        <TotalTimeSeconds>%.1f</TotalTimeSeconds>", session.duration))
        lines.append(String(format: "        <DistanceMeters>%.1f</DistanceMeters>", session.totalDistance ?? 0))
        if let calories = session.calories {
            lines.append("        <Calories>\(Int(calories))</Calories>")
        }
        lines.append("        <Intensity>Active</Intensity>")
        lines.append("        <TriggerMethod>Manual</TriggerMethod>")
        if points.count > 1 {
            lines.append("        <Track>")
            for point in points {
                lines.append("          <Trackpoint>")
                lines.append("            <Time>\(iso.string(from: point.timestamp))</Time>")
                lines.append("            <Position>")
                lines.append(String(format: "              <LatitudeDegrees>%.7f</LatitudeDegrees>", point.latitude))
                lines.append(String(format: "              <LongitudeDegrees>%.7f</LongitudeDegrees>", point.longitude))
                lines.append("            </Position>")
                lines.append(String(format: "            <AltitudeMeters>%.1f</AltitudeMeters>", point.altitude))
                lines.append(String(format: "            <DistanceMeters>%.1f</DistanceMeters>", point.distanceFromStart))
                lines.append("          </Trackpoint>")
            }
            lines.append("        </Track>")
        }
        lines.append("      </Lap>")
        lines.append("      <Notes>\(escape(session.notes ?? session.displayTitle))</Notes>")
        lines.append("    </Activity>")
        lines.append("  </Activities>")
        lines.append("</TrainingCenterDatabase>")
        return lines.joined(separator: "\n")
    }

    static func tcxFile(for session: WorkoutSession) -> URL? {
        DataExporter.write(tcx(for: session).data(using: .utf8),
                           filename: "workout-\(DataExporter.stamp()).tcx")
    }
}
