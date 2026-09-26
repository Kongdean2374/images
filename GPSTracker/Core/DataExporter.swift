import Foundation
import SwiftUI
import UIKit

/// CSV / PDF 匯出（全部在本機完成）。
enum DataExporter {

    // MARK: CSV

    static func csv(sessions: [WorkoutSession]) -> URL? {
        var lines: [String] = []
        lines.append("開始時間,結束時間,類型,時長(秒),距離(公尺),平均配速(秒/公里),累積爬升(公尺),累積下降(公尺),步數,次數,熱量(大卡),強度分數,路線,天氣,氣溫,備註")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for s in sessions.sorted(by: { $0.startDate > $1.startDate }) {
            let fields: [String] = [
                df.string(from: s.startDate),
                df.string(from: s.endDate),
                s.type.displayName,
                String(format: "%.0f", s.duration),
                s.totalDistance.map { String(format: "%.1f", $0) } ?? "",
                s.averagePace.map { String(format: "%.1f", $0) } ?? "",
                s.elevationGain.map { String(format: "%.1f", $0) } ?? "",
                s.elevationLoss.map { String(format: "%.1f", $0) } ?? "",
                s.stepCount.map(String.init) ?? "",
                s.repCount.map(String.init) ?? "",
                s.calories.map { String(format: "%.0f", $0) } ?? "",
                s.intensityScore.map { String(format: "%.1f", $0) } ?? "",
                s.routeKey ?? "",
                s.weatherNote ?? "",
                s.temperature.map { String(format: "%.1f", $0) } ?? "",
                s.notes ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        let text = lines.joined(separator: "\n")
        return write(text.data(using: .utf8), filename: "workouts-\(stamp()).csv")
    }

    /// 單次運動的軌跡點 CSV
    static func routeCSV(session: WorkoutSession) -> URL? {
        var lines = ["時間,緯度,經度,海拔(公尺),速度(公尺/秒),累積距離(公尺)"]
        let df = ISO8601DateFormatter()
        for p in session.sortedPoints {
            lines.append([df.string(from: p.timestamp),
                          String(format: "%.6f", p.latitude),
                          String(format: "%.6f", p.longitude),
                          String(format: "%.1f", p.altitude),
                          String(format: "%.2f", p.speed),
                          String(format: "%.1f", p.distanceFromStart)].joined(separator: ","))
        }
        return write(lines.joined(separator: "\n").data(using: .utf8),
                     filename: "route-\(stamp()).csv")
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: PDF 月報表

    @MainActor
    static func monthlyReport(sessions: [WorkoutSession],
                              month: Date,
                              chartImages: [UIImage]) -> URL? {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let monthStart = calendar.date(from: comps),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
        let inMonth = sessions.filter { $0.startDate >= monthStart && $0.startDate < monthEnd }
            .sorted { $0.startDate < $1.startDate }

        let pageWidth: CGFloat = 595.2   // A4 72dpi
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let headAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.darkGray
        ]

        let data = renderer.pdfData { ctx in
            var y: CGFloat = margin
            ctx.beginPage()

            ("\(Fmt.monthFormatter.string(from: monthStart)) 運動月報表" as NSString)
                .draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttrs)
            y += 38

            let totalDistance = inMonth.reduce(0.0) { $0 + ($1.totalDistance ?? 0) }
            let totalDuration = inMonth.reduce(0.0) { $0 + $1.duration }
            let totalCalories = inMonth.reduce(0.0) { $0 + ($1.calories ?? 0) }
            let paced = inMonth.compactMap { $0.averagePace }
            let avgPace = paced.isEmpty ? nil : paced.reduce(0, +) / Double(paced.count)

            let summary = """
            運動次數：\(inMonth.count) 次
            總里程：\(String(format: "%.2f", totalDistance / 1000)) 公里
            總時間：\(Fmt.duration(totalDuration))
            平均配速：\(Fmt.pace(avgPace))
            估算消耗：\(String(format: "%.0f", totalCalories)) 大卡
            """
            (summary as NSString).draw(in: CGRect(x: margin, y: y, width: pageWidth - margin * 2, height: 110),
                                       withAttributes: bodyAttrs)
            y += 110

            for image in chartImages {
                let maxW = pageWidth - margin * 2
                let scale = min(1, maxW / max(image.size.width, 1))
                let h = image.size.height * scale
                if y + h > pageHeight - margin {
                    ctx.beginPage()
                    y = margin
                }
                image.draw(in: CGRect(x: margin, y: y, width: image.size.width * scale, height: h))
                y += h + 18
            }

            if y + 60 > pageHeight - margin {
                ctx.beginPage()
                y = margin
            }
            ("明細" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: headAttrs)
            y += 22

            ("日期　類型　距離　時間　配速" as NSString)
                .draw(at: CGPoint(x: margin, y: y), withAttributes: bodyAttrs)
            y += 16

            for s in inMonth {
                if y + 16 > pageHeight - margin {
                    ctx.beginPage()
                    y = margin
                }
                let line = "\(Fmt.dateTime(s.startDate))　\(s.type.shortName)　\(Fmt.distance(s.totalDistance))　\(Fmt.duration(s.duration))　\(Fmt.pace(s.averagePace))"
                (line as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bodyAttrs)
                y += 16
            }
        }
        return write(data, filename: "report-\(Fmt.monthFormatter.string(from: monthStart).replacingOccurrences(of: "/", with: "-")).pdf")
    }

    // MARK: 共用

    @MainActor
    static func snapshot<V: View>(of view: V, width: CGFloat = 900, scale: CGFloat = 2) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = scale
        return renderer.uiImage
    }

    static func write(_ data: Data?, filename: String) -> URL? {
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
