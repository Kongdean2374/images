import Foundation
import ChaiNetCore

/// Writes export files to a temporary directory for the share sheet (user-initiated only).
enum ExportService {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ChaiNetExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func exportResults(_ results: [TestResult], format: ExportFormatSetting, includeLocation: Bool) throws -> URL {
        let options = ExportOptions(includeLocation: includeLocation, includeTimelines: true)
        let dir = try directory()
        switch format {
        case .json:
            let url = dir.appending(path: "ChaiNet-results-\(stamp()).json")
            try ResultExporter.json(results, options: options).write(to: url, options: .atomic)
            return url
        case .csv:
            let url = dir.appending(path: "ChaiNet-results-\(stamp()).csv")
            try Data(ResultExporter.csv(results, options: options).utf8).write(to: url, options: .atomic)
            return url
        case .text:
            let url = dir.appending(path: "ChaiNet-results-\(stamp()).txt")
            let text = results.map(ResultExporter.shareSummary).joined(separator: "\n\n---\n\n")
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        }
    }

    static func exportReport(_ report: DiagnosticReport, asJSON: Bool) throws -> URL {
        let generator = DiagnosticReportGenerator()
        let dir = try directory()
        if asJSON {
            let url = dir.appending(path: "ChaiNet-diagnostic-report-\(stamp()).json")
            try generator.json(report).write(to: url, options: .atomic)
            return url
        }
        let url = dir.appending(path: "ChaiNet-diagnostic-report-\(stamp()).txt")
        try Data(generator.text(report).utf8).write(to: url, options: .atomic)
        return url
    }

    static var platform: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Complete English raw-data export of one result (TXT or JSON).
    static func exportRawData(_ result: TestResult, analysis: RootCauseAnalysis?, asJSON: Bool, includeLocation: Bool,
                              privacy: ExportPrivacy = .aiSafe) throws -> URL {
        let dir = try directory()
        let tag = privacy.profile == .aiSafe ? "ai-safe" : "engineer"
        if asJSON {
            let url = dir.appending(path: "ChaiNet-\(tag)-\(stamp()).json")
            try RawDataExporter.json(result, analysis: analysis, appVersion: appVersion, platform: platform,
                                     includeLocation: includeLocation, privacy: privacy).write(to: url, options: .atomic)
            return url
        }
        let url = dir.appending(path: "ChaiNet-\(tag)-\(stamp()).txt")
        try Data(RawDataExporter.text(result, analysis: analysis, appVersion: appVersion, platform: platform,
                                      includeLocation: includeLocation, privacy: privacy).utf8).write(to: url, options: .atomic)
        return url
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
