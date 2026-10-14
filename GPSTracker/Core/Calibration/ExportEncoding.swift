import Foundation

enum ExportEncoding {
    static func csvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func xml(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
}

struct TCXRecord {
    struct Point { var time: Date; var latitude: Double; var longitude: Double; var altitude: Double; var distance: Double }
    var start: Date
    var end: Date
    var duration: Double
    var distance: Double?
    var calories: Double?
    var running: Bool
    var notes: String
    var points: [Point]
}
enum TCXEncoder {
    static func encode(_ record: TCXRecord) -> String {
        let iso = ISO8601DateFormatter()
        let start = iso.string(from: record.start)
        // Calories is required by the TCX schema. Zero means unavailable; notes disclose it.
        let calories = record.calories.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil } ?? 0
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\"><Activities>",
            "<Activity Sport=\"\(record.running ? "Running" : "Other")\"><Id>\(start)</Id>",
            "<Lap StartTime=\"\(start)\"><TotalTimeSeconds>\(ExportEncoding.number(max(0, record.duration)))</TotalTimeSeconds>",
            "<DistanceMeters>\(ExportEncoding.number(record.distance ?? 0))</DistanceMeters><Calories>\(calories)</Calories>",
            "<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>"]
        if !record.points.isEmpty {
            lines.append("<Track>")
            for point in record.points {
                guard point.latitude.isFinite, point.longitude.isFinite, abs(point.latitude) <= 90, abs(point.longitude) <= 180 else { continue }
                lines.append("<Trackpoint><Time>\(iso.string(from: point.time))</Time><Position><LatitudeDegrees>\(ExportEncoding.number(point.latitude, digits: 7))</LatitudeDegrees><LongitudeDegrees>\(ExportEncoding.number(point.longitude, digits: 7))</LongitudeDegrees></Position>")
                if point.altitude.isFinite { lines.append("<AltitudeMeters>\(ExportEncoding.number(point.altitude))</AltitudeMeters>") }
                if point.distance.isFinite { lines.append("<DistanceMeters>\(ExportEncoding.number(max(0, point.distance)))</DistanceMeters>") }
                lines.append("</Trackpoint>")
            }
            lines.append("</Track>")
        }
        let missing = (record.calories == nil ? "；熱量未知（TCX 必要欄位以 0 表示）" : "") + (record.distance == nil ? "；距離未知（TCX 必要欄位以 0 表示）" : "")
        lines.append("</Lap><Notes>\(ExportEncoding.xml(record.notes + missing))</Notes></Activity></Activities></TrainingCenterDatabase>")
        return lines.joined(separator: "\n")
    }
}
