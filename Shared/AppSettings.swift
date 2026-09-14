import Foundation

/// 存在 App Group UserDefaults 的輕量設定（Widget / Live Activity 也讀得到）。
enum AppSettings {
    private enum Key {
        static let liveActivityAutoCloseHours = "settings.liveActivityAutoCloseHours"
        static let quickAmounts = "settings.quickAmounts"
        static let keepReceiptImage = "settings.keepReceiptImage"
        static let didSeedDefaults = "settings.didSeedDefaults"
        static let appLockEnabled = "settings.appLockEnabled"
        static let dailyReminderEnabled = "settings.dailyReminderEnabled"
        static let dailyReminderHour = "settings.dailyReminderHour"
        static let dailyReminderMinute = "settings.dailyReminderMinute"
        static let overspendAlertEnabled = "settings.overspendAlertEnabled"
        static let didMigrateLegacyCloudStore = "settings.didMigrateLegacyCloudStore"
        static let legacyMigrationNote = "settings.legacyMigrationNote"
    }

    /// Live Activity 自動關閉時數（0 = 不自動關閉）。
    static var liveActivityAutoCloseHours: Int {
        get { (AppGroup.defaults.object(forKey: Key.liveActivityAutoCloseHours) as? Int) ?? 8 }
        set { AppGroup.defaults.set(newValue, forKey: Key.liveActivityAutoCloseHours) }
    }

    /// 記帳 Sheet 與 Widget 上的快速加值按鈕金額。
    static var quickAmounts: [Int] {
        get { (AppGroup.defaults.array(forKey: Key.quickAmounts) as? [Int]) ?? [50, 100, 150, 500] }
        set { AppGroup.defaults.set(newValue, forKey: Key.quickAmounts) }
    }

    /// OCR 後是否保留原始收據照片。
    static var keepReceiptImage: Bool {
        get { (AppGroup.defaults.object(forKey: Key.keepReceiptImage) as? Bool) ?? true }
        set { AppGroup.defaults.set(newValue, forKey: Key.keepReceiptImage) }
    }

    static var didSeedDefaults: Bool {
        get { AppGroup.defaults.bool(forKey: Key.didSeedDefaults) }
        set { AppGroup.defaults.set(newValue, forKey: Key.didSeedDefaults) }
    }

    /// Face ID / 密碼鎖
    static var appLockEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: Key.appLockEnabled) }
        set { AppGroup.defaults.set(newValue, forKey: Key.appLockEnabled) }
    }

    /// 每日記帳提醒
    static var dailyReminderEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: Key.dailyReminderEnabled) }
        set { AppGroup.defaults.set(newValue, forKey: Key.dailyReminderEnabled) }
    }

    static var dailyReminderHour: Int {
        get { (AppGroup.defaults.object(forKey: Key.dailyReminderHour) as? Int) ?? 21 }
        set { AppGroup.defaults.set(newValue, forKey: Key.dailyReminderHour) }
    }

    static var dailyReminderMinute: Int {
        get { (AppGroup.defaults.object(forKey: Key.dailyReminderMinute) as? Int) ?? 0 }
        set { AppGroup.defaults.set(newValue, forKey: Key.dailyReminderMinute) }
    }

    /// 超速消費警告
    static var overspendAlertEnabled: Bool {
        get { (AppGroup.defaults.object(forKey: Key.overspendAlertEnabled) as? Bool) ?? true }
        set { AppGroup.defaults.set(newValue, forKey: Key.overspendAlertEnabled) }
    }

    /// 舊版 iCloud 資料庫是否已搬回本機
    static var didMigrateLegacyCloudStore: Bool {
        get { AppGroup.defaults.bool(forKey: Key.didMigrateLegacyCloudStore) }
        set { AppGroup.defaults.set(newValue, forKey: Key.didMigrateLegacyCloudStore) }
    }

    /// 搬遷結果，啟動後給使用者看一次
    static var legacyMigrationNote: String? {
        get { AppGroup.defaults.string(forKey: Key.legacyMigrationNote) }
        set {
            if let newValue { AppGroup.defaults.set(newValue, forKey: Key.legacyMigrationNote) }
            else { AppGroup.defaults.removeObject(forKey: Key.legacyMigrationNote) }
        }
    }

    /// 清掉 v1 的 iCloud 相關設定
    static func purgeLegacyCloudKeys() {
        for key in ["settings.cloudSyncEnabled", "settings.cloudLaunchInProgress", "settings.cloudFailureNote"] {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }
}
