import Foundation

/// 資料完整性檢查：讓使用者知道哪些統計還缺資料、哪裡可以補。
struct IntegrityIssue: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case info = 0, warning = 1, problem = 2
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id = UUID()
    let title: String
    let detail: String
    let severity: Severity
    let count: Int
}

struct IntegrityReport {
    var total = 0
    var missingDistance = 0
    var missingDuration = 0
    var missingPace = 0
    var missingSteps = 0
    var missingRPE = 0
    var missingWeather = 0
    var notSyncedToHealth = 0
    var gpsWithoutRoute = 0
    var duplicateSuspects = 0
    var calibrationSamples = 0
    var coverageDays = 0
    var firstDate: Date?
    var lastDate: Date?
    var issues: [IntegrityIssue] = []
    /// 0...1
    var completeness: Double = 0

    var completenessPercent: Int { Int((completeness * 100).rounded()) }

    var grade: String {
        switch completeness {
        case ..<0.4: return "資料稀疏"
        case ..<0.65: return "尚可"
        case ..<0.85: return "良好"
        default: return "非常完整"
        }
    }
}

enum DataIntegrity {

    static func report(sessions: [WorkoutSession], calendar: Calendar = .current) -> IntegrityReport {
        var report = IntegrityReport()
        report.total = sessions.count
        guard !sessions.isEmpty else { return report }

        let sorted = sessions.sorted { $0.startDate < $1.startDate }
        report.firstDate = sorted.first?.startDate
        report.lastDate = sorted.last?.startDate
        if let first = report.firstDate, let last = report.lastDate {
            report.coverageDays = max(1, Int(last.timeIntervalSince(first) / 86400) + 1)
        }

        for session in sessions {
            if (session.totalDistance ?? 0) <= 0 { report.missingDistance += 1 }
            if session.duration <= 0 { report.missingDuration += 1 }
            if session.averagePace == nil && (session.totalDistance ?? 0) > 0 { report.missingPace += 1 }
            if session.stepCount == nil { report.missingSteps += 1 }
            if session.rpe == nil { report.missingRPE += 1 }
            if (session.weatherNote ?? "").isEmpty { report.missingWeather += 1 }
            if !session.healthKitSynced { report.notSyncedToHealth += 1 }
            if session.type.requiresLocation && session.routePoints.isEmpty { report.gpsWithoutRoute += 1 }
            if let distance = session.totalDistance, let steps = session.stepCount,
               distance > 300, steps > 300 {
                report.calibrationSamples += 1
            }
        }

        // 疑似重複：同類型且開始時間相差兩分鐘內
        for index in 1..<max(1, sorted.count) {
            let previous = sorted[index - 1]
            let current = sorted[index]
            if current.type == previous.type,
               abs(current.startDate.timeIntervalSince(previous.startDate)) < 120 {
                report.duplicateSuspects += 1
            }
        }

        let total = Double(sessions.count)
        // 各欄位覆蓋率的加權平均
        let distanceCoverage = 1 - Double(report.missingDistance) / total
        let stepCoverage = 1 - Double(report.missingSteps) / total
        let rpeCoverage = 1 - Double(report.missingRPE) / total
        let paceCoverage = 1 - Double(report.missingPace) / total
        let weatherCoverage = 1 - Double(report.missingWeather) / total
        let volumeScore = min(1, total / 30)

        report.completeness = min(1, 0.28 * distanceCoverage
                                  + 0.2 * stepCoverage
                                  + 0.14 * paceCoverage
                                  + 0.12 * rpeCoverage
                                  + 0.06 * weatherCoverage
                                  + 0.2 * volumeScore)

        var issues: [IntegrityIssue] = []
        if report.missingDistance > 0 {
            issues.append(IntegrityIssue(title: "\(report.missingDistance) 筆沒有距離",
                                         detail: "間歇與原地運動本來就沒有距離，屬正常；若是走路或跑步，代表當時沒抓到步數。",
                                         severity: .info,
                                         count: report.missingDistance))
        }
        if report.missingSteps > 0 {
            issues.append(IntegrityIssue(title: "\(report.missingSteps) 筆沒有步數",
                                         detail: "沒有步數就無法拿來校正步幅。開啟計步權限後的紀錄都會自動帶入。",
                                         severity: .warning,
                                         count: report.missingSteps))
        }
        if report.missingRPE > 0 {
            issues.append(IntegrityIssue(title: "\(report.missingRPE) 筆沒有自覺強度",
                                         detail: "在紀錄詳情頁補上 RPE，訓練負荷會算得更貼近真實感受。",
                                         severity: .info,
                                         count: report.missingRPE))
        }
        if report.gpsWithoutRoute > 0 {
            issues.append(IntegrityIssue(title: "\(report.gpsWithoutRoute) 筆 GPS 紀錄沒有軌跡點",
                                         detail: "可能是當時訊號不足或中途關閉權限，地圖與分段配速會無法顯示。",
                                         severity: .problem,
                                         count: report.gpsWithoutRoute))
        }
        if report.duplicateSuspects > 0 {
            issues.append(IntegrityIssue(title: "\(report.duplicateSuspects) 組疑似重複紀錄",
                                         detail: "同類型且開始時間相近，可能是重複儲存，建議到紀錄列表確認後刪除。",
                                         severity: .warning,
                                         count: report.duplicateSuspects))
        }
        if report.notSyncedToHealth > 0 {
            issues.append(IntegrityIssue(title: "\(report.notSyncedToHealth) 筆未寫入健康 App",
                                         detail: "在設定頁按「補傳未同步的紀錄」即可一次補上（需要健康權限）。",
                                         severity: .info,
                                         count: report.notSyncedToHealth))
        }
        if report.calibrationSamples < 5 {
            issues.append(IntegrityIssue(title: "可校正樣本只有 \(report.calibrationSamples) 筆",
                                         detail: "同時含距離與步數的紀錄越多，步幅精準度越高。也可以在校正中心直接讀健康 App 的歷史資料。",
                                         severity: .warning,
                                         count: report.calibrationSamples))
        }
        report.issues = issues.sorted { $0.severity > $1.severity }
        return report
    }

    /// 步頻統計
    static func cadenceStats(sessions: [WorkoutSession]) -> (average: Double, best: Double, samples: Int)? {
        let values = sessions.compactMap { $0.cadence }.filter { $0 > 40 && $0 < 250 }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), values.max() ?? 0, values.count)
    }
}
