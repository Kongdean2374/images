import SwiftUI
import CoreMotion

/// Widget 專用的輕量工具（獨立於主 App，不共用程式碼）。
enum WidgetTheme {
    static let accent = Color(red: 0.196, green: 0.478, blue: 0.902)
    static let mint = Color(red: 0.207, green: 0.851, blue: 0.635)
    static let amber = Color(red: 1.0, green: 0.741, blue: 0.259)
    static let warm = Color(red: 1.0, green: 0.376, blue: 0.282)
}

enum WidgetFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func distance(_ meters: Double) -> String {
        meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.2f km", meters / 1000)
    }

    static func pace(_ secondsPerKM: Double?) -> String {
        guard let secondsPerKM, secondsPerKM > 0, secondsPerKM.isFinite, secondsPerKM < 5400 else { return "--'--\"" }
        return String(format: "%d'%02d\"", Int(secondsPerKM) / 60, Int(secondsPerKM) % 60)
    }
}

/// Widget 直接向系統查今日步數，即使沒有 App Group 也能運作。
enum WidgetPedometer {
    static func todayStats() async -> (steps: Int, floors: Int, distance: Double?) {
        guard CMPedometer.isStepCountingAvailable() else { return (0, 0, nil) }
        let start = Calendar.current.startOfDay(for: Date())
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: Date()) { data, _ in
                continuation.resume(returning: (data?.numberOfSteps.intValue ?? 0,
                                                data?.floorsAscended?.intValue ?? 0,
                                                data?.distance?.doubleValue))
            }
        }
    }

    /// 步數目標：有 App Group 時讀 App 的設定，否則用預設值
    static var stepGoal: Int {
        let shared = UserDefaults(suiteName: "group.com.gpstracker.app")
        let value = shared?.integer(forKey: "dailyStepGoal") ?? 0
        if value > 0 { return value }
        let local = UserDefaults.standard.integer(forKey: "dailyStepGoal")
        return local > 0 ? local : 8000
    }
}
