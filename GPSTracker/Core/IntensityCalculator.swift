import Foundation

/// 心肺負荷／強度估算（純公式，不依賴心率裝置）。
enum IntensityCalculator {

    /// 相對強度分數 0-100。
    /// 綜合：配速強度、爬升負荷、時長負荷。
    static func score(type: WorkoutType,
                      duration: TimeInterval,
                      distance: Double?,
                      averagePace: Double?,
                      elevationGain: Double?) -> Double {
        var paceFactor = 0.45
        if let pace = averagePace, pace > 0 {
            // 8'00"/km 視為輕鬆(0.25)，4'00"/km 視為極高(1.0)
            let clamped = min(max(pace, 210), 540)
            paceFactor = 1.0 - (clamped - 210) / 330 * 0.75
        } else if type == .indoorInterval {
            paceFactor = 0.8
        } else if type == .indoorReps {
            paceFactor = 0.7
        }

        var climbFactor = 0.0
        if let gain = elevationGain, let dist = distance, dist > 100 {
            // 每公里爬升 50 公尺 ≈ +0.15
            let gradePerKM = gain / (dist / 1000)
            climbFactor = min(0.3, gradePerKM / 50 * 0.15)
        }

        // 時長負荷：30 分鐘為基準
        let durationFactor = min(1.4, 0.55 + duration / 3600 * 0.55)

        let raw = (paceFactor + climbFactor) * durationFactor * type.metValue / 9.0
        return min(100, max(0, raw * 100))
    }

    /// 估算消耗熱量（大卡）：MET × 體重(kg) × 小時
    static func calories(type: WorkoutType, duration: TimeInterval, bodyWeight: Double) -> Double {
        type.metValue * bodyWeight * (duration / 3600)
    }

    /// 指定 MET 的版本（用於運動目錄裡的各種項目）
    static func calories(met: Double, duration: TimeInterval, bodyWeight: Double) -> Double {
        met * bodyWeight * (duration / 3600)
    }

    /// 以 MET 直接計算強度分數
    static func score(met: Double,
                      duration: TimeInterval,
                      distance: Double?,
                      averagePace: Double?,
                      elevationGain: Double?) -> Double {
        var paceFactor = min(1.0, max(0.25, met / 11.0))
        if let pace = averagePace, pace > 0 {
            let clamped = min(max(pace, 210), 540)
            paceFactor = 1.0 - (clamped - 210) / 330 * 0.75
        }
        var climbFactor = 0.0
        if let gain = elevationGain, let dist = distance, dist > 100 {
            climbFactor = min(0.3, gain / (dist / 1000) / 50 * 0.15)
        }
        let durationFactor = min(1.4, 0.55 + duration / 3600 * 0.55)
        let raw = (paceFactor + climbFactor) * durationFactor * met / 9.0
        return min(100, max(0, raw * 100))
    }

    static func label(for score: Double?) -> String {
        guard let score else { return "--" }
        switch score {
        case ..<25: return "輕鬆"
        case ..<45: return "穩定"
        case ..<65: return "中強度"
        case ..<85: return "高強度"
        default: return "極限"
        }
    }
}
