import Foundation

/// 存在 App Group UserDefaults 的輕量設定（Widget / Live Activity 也讀得到）。
enum AppSettings {
    private enum Key {
        static let cloudSyncEnabled = "settings.cloudSyncEnabled"
        static let liveActivityAutoCloseHours = "settings.liveActivityAutoCloseHours"
        static let quickAmounts = "settings.quickAmounts"
        static let keepReceiptImage = "settings.keepReceiptImage"
        static let didSeedDefaults = "settings.didSeedDefaults"
        static let cloudLaunchInProgress = "settings.cloudLaunchInProgress"
        static let cloudFailureNote = "settings.cloudFailureNote"
    }

    /// 正在嘗試開 CloudKit 容器的旗標。啟動時看到它還是 true，代表上次在這段閃退了。
    static var cloudLaunchInProgress: Bool {
        get { AppGroup.defaults.bool(forKey: Key.cloudLaunchInProgress) }
        set { AppGroup.defaults.set(newValue, forKey: Key.cloudLaunchInProgress) }
    }

    /// iCloud 開不成時要顯示給使用者看的說明
    static var cloudFailureNote: String? {
        get { AppGroup.defaults.string(forKey: Key.cloudFailureNote) }
        set {
            if let newValue {
                AppGroup.defaults.set(newValue, forKey: Key.cloudFailureNote)
            } else {
                AppGroup.defaults.removeObject(forKey: Key.cloudFailureNote)
            }
        }
    }

    /// 可選功能：iCloud 私人同步開關。切換後需要重開 App 才會換容器。
    static var cloudSyncEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: Key.cloudSyncEnabled) }
        set { AppGroup.defaults.set(newValue, forKey: Key.cloudSyncEnabled) }
    }

    /// Live Activity 自動關閉時數（0 = 不自動關閉，手動關為止）。
    static var liveActivityAutoCloseHours: Int {
        get {
            let stored = AppGroup.defaults.object(forKey: Key.liveActivityAutoCloseHours) as? Int
            return stored ?? 8
        }
        set { AppGroup.defaults.set(newValue, forKey: Key.liveActivityAutoCloseHours) }
    }

    /// 記帳 Sheet 上的快速加值按鈕金額。
    static var quickAmounts: [Int] {
        get {
            let stored = AppGroup.defaults.array(forKey: Key.quickAmounts) as? [Int]
            return stored ?? [50, 100, 150, 500]
        }
        set { AppGroup.defaults.set(newValue, forKey: Key.quickAmounts) }
    }

    /// 可選功能：OCR 後是否保留原始收據照片。
    static var keepReceiptImage: Bool {
        get {
            let stored = AppGroup.defaults.object(forKey: Key.keepReceiptImage) as? Bool
            return stored ?? true
        }
        set { AppGroup.defaults.set(newValue, forKey: Key.keepReceiptImage) }
    }

    static var didSeedDefaults: Bool {
        get { AppGroup.defaults.bool(forKey: Key.didSeedDefaults) }
        set { AppGroup.defaults.set(newValue, forKey: Key.didSeedDefaults) }
    }
}
