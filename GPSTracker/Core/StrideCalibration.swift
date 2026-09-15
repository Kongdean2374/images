import Foundation

/// 個人步幅校正：用有 GPS 的場次學習「距離 ÷ 步數」，
/// 之後在完全沒有定位訊號時換算距離，比系統的通用估算準。
enum StrideCalibration {

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static func stride(_ profile: StrideProfile) -> String { "stride.\(profile.rawValue)" }
        static func samples(_ profile: StrideProfile) -> String { "strideSamples.\(profile.rawValue)" }
        static func updated(_ profile: StrideProfile) -> String { "strideUpdated.\(profile.rawValue)" }
    }

    /// 尚未校正前的預設值（成年人平均）
    static func defaultStride(_ profile: StrideProfile) -> Double {
        profile == .walking ? 0.72 : 1.05
    }

    static func stride(_ profile: StrideProfile) -> Double {
        let value = defaults.double(forKey: Keys.stride(profile))
        return value > 0.2 ? value : defaultStride(profile)
    }

    static func sampleCount(_ profile: StrideProfile) -> Int {
        defaults.integer(forKey: Keys.samples(profile))
    }

    static func lastUpdated(_ profile: StrideProfile) -> Date? {
        let interval = defaults.double(forKey: Keys.updated(profile))
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    static func isCalibrated(_ profile: StrideProfile) -> Bool {
        sampleCount(profile) > 0
    }

    /// 校正過的步幅換算距離（公尺）
    static func distance(steps: Int, profile: StrideProfile) -> Double {
        Double(steps) * stride(profile)
    }

    /// 用一次可信的場次更新步幅（指數移動平均，越跑越準）
    @discardableResult
    static func learn(distance: Double, steps: Int, profile: StrideProfile) -> Double? {
        // 太短或步數太少的場次不列入，避免污染
        guard distance > 300, steps > 400 else { return nil }
        let measured = distance / Double(steps)
        // 合理範圍以外視為雜訊（例如騎車、搭車）
        guard measured > 0.3, measured < 2.2 else { return nil }

        let count = sampleCount(profile)
        let current = count > 0 ? stride(profile) : measured
        // 前幾次權重高，之後穩定下來
        let weight = count == 0 ? 1.0 : max(0.15, 1.0 / Double(count + 1))
        let updated = current * (1 - weight) + measured * weight

        defaults.set(updated, forKey: Keys.stride(profile))
        defaults.set(count + 1, forKey: Keys.samples(profile))
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updated(profile))
        return updated
    }

    /// 跑步機輸入實際距離後反推步幅
    @discardableResult
    static func calibrate(withActualDistance distance: Double, steps: Int, profile: StrideProfile) -> Double? {
        guard distance > 100, steps > 150 else { return nil }
        let measured = distance / Double(steps)
        guard measured > 0.3, measured < 2.2 else { return nil }
        let count = sampleCount(profile)
        let current = count > 0 ? stride(profile) : measured
        let updated = current * 0.5 + measured * 0.5
        defaults.set(updated, forKey: Keys.stride(profile))
        defaults.set(count + 1, forKey: Keys.samples(profile))
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updated(profile))
        return updated
    }

    static func reset(_ profile: StrideProfile) {
        defaults.removeObject(forKey: Keys.stride(profile))
        defaults.removeObject(forKey: Keys.samples(profile))
        defaults.removeObject(forKey: Keys.updated(profile))
    }
}
