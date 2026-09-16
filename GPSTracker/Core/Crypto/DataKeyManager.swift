import Foundation
import CryptoKit
import Combine

/// 金鑰管理模組：Key A 的生成、保管、查詢與刪除。
/// Key A 只存在這支手機的 Keychain 裡，永遠不會原樣離開裝置。
final class DataKeyManager: ObservableObject {
    static let shared = DataKeyManager()

    private let keyAccount = "dataKeyA"
    private let deviceAccount = "deviceIdentifier"

    @Published private(set) var hasKey: Bool = false
    /// 金鑰指紋（SHA-256 前 8 bytes），用來比對兩支手機是不是同一把金鑰
    @Published private(set) var fingerprint: String = "—"
    @Published private(set) var createdAt: Date?

    private let createdKey = "e2eeKeyCreatedAt"

    private init() {
        refresh()
    }

    // MARK: 查詢

    func refresh() {
        let data = KeychainStore.load(account: keyAccount)
        hasKey = data != nil
        fingerprint = data.map { Self.fingerprint(of: $0) } ?? "—"
        let stamp = UserDefaults.standard.double(forKey: createdKey)
        createdAt = (hasKey && stamp > 0) ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// 取得 Key A，沒有的話回 nil（不會自動生成，避免覆蓋剛匯入的金鑰）
    func currentKey() -> SymmetricKey? {
        guard let data = KeychainStore.load(account: keyAccount) else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: 生成

    /// 首次啟用時呼叫：沒有金鑰就用系統亂數產生器生成一把 256-bit Key A
    @discardableResult
    func ensureKey() throws -> SymmetricKey {
        if let existing = currentKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainStore.save(data, account: keyAccount)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: createdKey)
        refresh()
        return key
    }

    /// 匯入他人／舊裝置的金鑰，直接覆蓋現有的 Key A
    func replaceKey(with key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainStore.save(data, account: keyAccount)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: createdKey)
        refresh()
    }

    /// 刪除金鑰。伺服器上的密文會因此永久無法解密，UI 要再三確認。
    func deleteKey() {
        KeychainStore.delete(account: keyAccount)
        UserDefaults.standard.removeObject(forKey: createdKey)
        refresh()
    }

    // MARK: 裝置識別碼（不含個資，隨機產生）

    var deviceIdentifier: String {
        if let data = KeychainStore.load(account: deviceAccount),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        let generated = UUID().uuidString
        try? KeychainStore.save(Data(generated.utf8), account: deviceAccount)
        return generated
    }

    // MARK: 指紋

    static func fingerprint(of keyData: Data) -> String {
        let digest = SHA256.hash(data: keyData)
        return digest.prefix(8)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }

    var fingerprintOfCurrentKey: String {
        guard let data = KeychainStore.load(account: keyAccount) else { return "—" }
        return Self.fingerprint(of: data)
    }
}
