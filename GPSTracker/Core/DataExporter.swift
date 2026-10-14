import Foundation
import SwiftUI
import UIKit

/// CSV / PDF 匯出（全部在本機完成）。
enum DataExporter {

    // MARK: CSV

    static let summaryHeaders = ["運動UUID", "開始時間", "結束時間", "運動類型", "有效秒數", "牆上秒數", "暫停秒數", "距離公尺", "距離來源", "步數", "平均步頻", "平均配速秒每公里", "平均步幅公尺", "走路秒數", "跑步秒數", "其他未知秒數", "熱量大卡", "爬升公尺", "下降公尺", "上樓層", "下樓層", "負重公斤", "手機位置", "品質等級", "訓練候選資格", "排除原因碼", "來源App", "HealthKitUUID", "備註", "資料列類型", "區段起點", "區段終點", "緯度", "經度", "GPS精度公尺", "海拔公尺", "速度公尺每秒", "累積距離公尺", "增量步數", "增量距離公尺", "區段步頻", "區段來源", "區段動作"]

    static func summaryFields(_ s: WorkoutSession) -> [String] {
        let iso = ISO8601DateFormatter()
        let decision = s.calibrationDecision ?? CalibrationDecision(grade: .c, eligible: false, reasons: [.missingData], gpsCoverage: nil, stride: nil)
        let wall = max(0, s.endDate.timeIntervalSince(s.startDate))
        return [s.id.uuidString, iso.string(from: s.startDate), iso.string(from: s.endDate), s.type.displayName,
                ExportEncoding.number(s.duration), ExportEncoding.number(wall), ExportEncoding.number(max(0, wall - s.duration)),
                ExportEncoding.number(s.totalDistance), s.evidence.method.label, s.stepCount.map(String.init) ?? "",
                ExportEncoding.number(s.cadence), ExportEncoding.number(s.averagePace), ExportEncoding.number(s.strideLength),
                ExportEncoding.number(s.walkingSeconds), ExportEncoding.number(s.runningSeconds), ExportEncoding.number(s.otherSeconds),
                ExportEncoding.number(s.calories), ExportEncoding.number(s.elevationGain), ExportEncoding.number(s.elevationLoss),
                s.floorsAscended.map(String.init) ?? "", s.floorsDescended.map(String.init) ?? "", ExportEncoding.number(s.loadWeight),
                s.evidence.carryPosition.label, decision.grade.rawValue, decision.eligible ? "可訓練候選" : "排除／待確認",
                decision.reasons.map(\.rawValue).joined(separator: ";"), s.sourceApp ?? s.evidence.sourceBundle ?? "", s.healthKitUUID ?? "", s.notes ?? ""]
    }
    static func csv(sessions: [WorkoutSession]) -> URL? {
        let rows = [summaryHeaders] + sessions.sorted { $0.startDate > $1.startDate }.map {
            summaryFields($0) + ["summary"] + Array(repeating: "", count: summaryHeaders.count - 30)
        }
        return write(ExportEncoding.csv(rows).data(using: .utf8), filename: "workouts-\(stamp()).csv")
    }
    /// Every single-workout export includes a summary, plus only actual route/window data.
    static func sessionCSVText(_ session: WorkoutSession) -> String {
        let base = summaryFields(session)
        let iso = ISO8601DateFormatter()
        var rows = [summaryHeaders, base + ["summary"] + Array(repeating: "", count: summaryHeaders.count - 30)]
        for p in session.sortedPoints {
            rows.append(base + ["route", iso.string(from: p.timestamp), "", ExportEncoding.number(p.latitude, digits: 7),
                ExportEncoding.number(p.longitude, digits: 7), ExportEncoding.number(p.horizontalAccuracy), ExportEncoding.number(p.altitude),
                ExportEncoding.number(p.speed >= 0 ? p.speed : nil), ExportEncoding.number(p.distanceFromStart), "", "", "", "GPS原始點", ""])
        }
        if let data = session.estimateWindowsJSON?.data(using: .utf8), let windows = try? JSONDecoder().decode([EstimateWindow].self, from: data) {
            for w in windows {
                rows.append(base + ["window", iso.string(from: w.start), iso.string(from: w.end), "", "", "", "", "", "", String(w.steps),
                                    ExportEncoding.number(w.distance), ExportEncoding.number(w.cadence), w.source, w.motion])
            }
        }
        return ExportEncoding.csv(rows)
    }
    static func routeCSV(session: WorkoutSession) -> URL? {
        write(sessionCSVText(session).data(using: .utf8), filename: "workout-\(stamp()).csv")
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

    private static let errorLock = NSLock()
    private static var writeError: String?
    static var lastWriteError: String? { errorLock.lock(); defer { errorLock.unlock() }; return writeError }
    private static func setError(_ message: String?) { errorLock.lock(); writeError = message; errorLock.unlock() }
    static func write(_ data: Data?, filename: String) -> URL? {
        setError(nil)
        guard let data, !data.isEmpty else { setError("匯出內容為空，未建立檔案"); return nil }
        // Unique directories retain the exact file until iOS finishes sharing it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exports/" + UUID().uuidString)
        let url = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            setError("檔案寫入失敗：" + error.localizedDescription)
            return nil
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
