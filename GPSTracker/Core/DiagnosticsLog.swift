import Foundation
import UIKit
import CoreLocation

/// 診斷紀錄。
///
/// 運動在背景被系統終止時，App 沒有機會留下任何訊息——下次開啟只知道
/// 「有一筆沒結束的紀錄」，不知道為什麼。這裡把關鍵事件持續寫到磁碟，
/// 並在啟動時比對「有沒有正常結束的標記」，藉此判定上次是不是被強制終止，
/// 連同當時的狀態一起記下來，方便回報與修復。
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    enum Level: String, Codable {
        case info, warning, error

        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    struct Entry: Codable, Identifiable {
        var id: String { "\(date.timeIntervalSince1970)-\(message)" }
        let date: Date
        let level: Level
        /// 事件分類，例如 recording、location、lifecycle
        let category: String
        let message: String
        /// 附帶的技術細節，回報時最有用的部分
        let detail: [String: String]
    }

    private let fileName = "diagnostics.json"
    private let markerName = "clean-exit.marker"
    private let maxEntries = 400
    private let queue = DispatchQueue(label: "com.gpstracker.diagnostics", qos: .utility)

    private(set) var entries: [Entry] = []

    private var directory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
    }

    private init() {
        entries = load()
    }

    // MARK: 寫入

    func log(_ level: Level,
             category: String,
             _ message: String,
             detail: [String: String] = [:]) {
        var merged = detail
        merged["mem"] = Self.memoryFootprintText
        merged["batt"] = Self.batteryText

        let entry = Entry(date: Date(),
                          level: level,
                          category: category,
                          message: message,
                          detail: merged)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let url = directory?.appendingPathComponent(fileName) else { return }
        let snapshot = entries
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() -> [Entry] {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    // MARK: 非正常結束偵測

    private var markerURL: URL? { directory?.appendingPathComponent(markerName) }

    /// 開始記錄時呼叫：清掉「乾淨結束」標記。
    /// 只要這個標記不存在，就代表上次執行沒有走到正常結束流程。
    func markRecordingStarted() {
        guard let markerURL else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// 正常結束記錄時呼叫：放下標記
    func markCleanExit() {
        guard let markerURL else { return }
        try? Data("ok".utf8).write(to: markerURL, options: .atomic)
    }

    /// App 啟動時檢查上次是不是被強制終止
    func checkPreviousRun() {
        guard let markerURL else { return }
        let hadCleanExit = FileManager.default.fileExists(atPath: markerURL.path)
        guard !hadCleanExit else { return }

        // 沒有乾淨結束標記，而且還留著進行中的自動存檔 → 上次是被中斷的
        guard let snapshot = ActiveWorkoutStore.shared.load() else {
            // 沒有進行中的資料，補上標記避免每次啟動都報
            markCleanExit()
            return
        }

        let gap = Date().timeIntervalSince(snapshot.savedAt)
        log(.error,
            category: "lifecycle",
            "上次的運動記錄被強制中斷",
            detail: [
                "運動": snapshot.type.displayName,
                "項目": snapshot.sport?.name ?? "—",
                "開始時間": Self.timestamp(snapshot.startDate),
                "最後存檔": Self.timestamp(snapshot.savedAt),
                "距離中斷": String(format: "%.0f 秒", gap),
                "已記時間": String(format: "%.0f 秒", snapshot.elapsed),
                "已記距離": String(format: "%.0f m", snapshot.distance),
                "軌跡點數": "\(snapshot.points.count)",
                "空白段": "\(snapshot.gaps?.count ?? 0)",
                "推測原因": gap < 60
                    ? "存檔後很快被終止，可能是記憶體不足或背景用量過高"
                    : "存檔後超過一分鐘才被終止，可能是使用者從多工滑掉或系統回收"
            ])
        markCleanExit()
    }

    // MARK: 環境資訊

    static var environmentDetail: [String: String] {
        [
            "App 版本": appVersion,
            "系統": "iOS \(UIDevice.current.systemVersion)",
            "機型": deviceModel,
            "低電量模式": ProcessInfo.processInfo.isLowPowerModeEnabled ? "開啟" : "關閉",
            "電量": batteryText,
            "記憶體": memoryFootprintText,
            "定位權限": authorizationText,
            "精確定位": LocationManager.shared.isReducedAccuracy ? "僅大約位置" : "精確"
        ]
    }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    static var authorizationText: String {
        switch LocationManager.shared.authorizationStatus {
        case .authorizedAlways: return "永遠允許"
        case .authorizedWhenInUse: return "使用期間"
        case .denied: return "拒絕"
        case .restricted: return "受限"
        case .notDetermined: return "尚未詢問"
        @unknown default: return "未知"
        }
    }

    static var batteryText: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "未知" }
        return String(format: "%.0f%%", level * 100)
    }

    static var memoryFootprintText: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "未知" }
        return String(format: "%.0f MB", Double(info.phys_footprint) / 1_048_576)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: 匯出

    /// 產生可以直接貼給開發者的純文字報告
    func exportText() -> String {
        var lines: [String] = []
        lines.append("=== 軌跡記錄器 診斷報告 ===")
        lines.append("產生時間：\(Self.timestamp(Date()))")
        lines.append("")
        lines.append("--- 環境 ---")
        for (key, value) in Self.environmentDetail.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)：\(value)")
        }
        lines.append("")
        lines.append("--- 事件（新到舊，共 \(entries.count) 筆）---")
        for entry in entries.reversed() {
            lines.append("[\(Self.timestamp(entry.date))] \(entry.level.rawValue.uppercased()) \(entry.category)　\(entry.message)")
            for (key, value) in entry.detail.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key)：\(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func exportFile() -> URL? {
        let name = "diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard let data = exportText().data(using: .utf8) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }
}
