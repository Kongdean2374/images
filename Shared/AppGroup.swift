import Foundation

/// 全 App 共用的識別碼與路徑。
/// 若要改成自己的 Bundle ID，只需要改這一個檔案 + project.yml + entitlements。
enum AppGroup {
    /// App Group：主 App 與 Widget / Live Activity 共享資料的容器。
    static let identifier = "group.com.moneyleft.app"

    /// iCloud（CloudKit）容器 ID —— 對應「可選功能：iCloud 私人同步」。
    static let cloudKitContainerID = "iCloud.com.moneyleft.app"

    /// URL Scheme，供 Widget / Live Activity 點擊後深連結回 App。
    static let urlScheme = "moneyleft"

    /// 共用的資料夾。取不到 App Group（例如側載未帶 entitlement）時退回 App 自己的沙盒。
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
    }

    /// 共用 UserDefaults（Widget 讀取快照用）。取不到 App Group 時退回 standard。
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
