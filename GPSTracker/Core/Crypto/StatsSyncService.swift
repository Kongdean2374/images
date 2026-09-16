import Foundation
import CryptoKit
import Combine

/// 要上傳的統計資料（明文結構）。只放彙總數字，不放座標、不放個資。
struct StatsPacket: Codable {
    var generatedAt: Date
    var totalWorkouts: Int
    var totalDistance: Double
    var totalDuration: TimeInterval
    var totalCalories: Double
    var weeklyDistance: Double
    var weeklyDuration: TimeInterval
    var longestDistance: Double
    var bestPace: Double?
    var currentStreak: Int
    var byType: [String: Int]
}

/// 上傳給伺服器的密文封包，對應規劃書第四節。
struct EncryptedEnvelope: Codable {
    /// 隨機產生的裝置識別碼，不含個資
    let deviceID: String
    /// 時間戳記
    let timestamp: Date
    /// 這次加密用的初始化向量
    let iv: String
    /// 密文本體
    let ciphertext: String
    /// 封包格式版本
    var version: Int = 1
}

/// 網路傳輸模組：只負責搬運密文，完全不碰加解密邏輯。
/// 沒有設定伺服器位址時整個功能維持關閉，App 其餘功能不受影響。
final class StatsSyncService: ObservableObject {
    static let shared = StatsSyncService()

    enum SyncError: LocalizedError {
        case notConfigured
        case insecureURL
        case noKey
        case server(Int, String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未設定同步伺服器位址"
            case .insecureURL: return "只接受 HTTPS 位址，不允許明文 HTTP"
            case .noKey: return "這支手機還沒有資料金鑰"
            case .server(let code, let message):
                return "伺服器回應 \(code)：\(message)"
            case .network(let message): return "連線失敗：\(message)"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var baseURLText: String {
        didSet { UserDefaults.standard.set(baseURLText, forKey: Keys.baseURL) }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }
    @Published private(set) var lastSyncAt: Date?
    /// 伺服器存取密鑰（不是加密金鑰，只用來擋掉不認識的請求）。存在 Keychain。
    @Published var accessToken: String {
        didSet {
            if accessToken.isEmpty {
                KeychainStore.delete(account: Self.tokenAccount)
            } else {
                try? KeychainStore.save(Data(accessToken.utf8), account: Self.tokenAccount)
            }
        }
    }

    private static let tokenAccount = "syncAccessToken"

    private enum Keys {
        static let baseURL = "syncBaseURL"
        static let enabled = "syncEnabled"
        static let lastSync = "syncLastAt"
    }

    private let session: URLSession

    private init() {
        baseURLText = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        accessToken = KeychainStore.load(account: Self.tokenAccount)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        let stamp = UserDefaults.standard.double(forKey: Keys.lastSync)
        lastSyncAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var isConfigured: Bool { resolvedBaseURL != nil }

    private var resolvedBaseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    // MARK: 上傳

    /// 把統計資料在「離開手機之前」就加密好再送出，伺服器全程只看得到密文。
    func upload(_ packet: StatsPacket) async throws {
        guard enabled else { throw SyncError.notConfigured }
        guard let base = resolvedBaseURL else {
            throw baseURLText.isEmpty ? SyncError.notConfigured : SyncError.insecureURL
        }
        guard let key = DataKeyManager.shared.currentKey() else { throw SyncError.noKey }

        await setStatus(.working("加密中⋯"))
        let sealed = try CryptoBox.encrypt(packet, key: key)
        let envelope = EncryptedEnvelope(deviceID: DataKeyManager.shared.deviceIdentifier,
                                         timestamp: Date(),
                                         iv: sealed.iv,
                                         ciphertext: sealed.ciphertext)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: base.appendingPathComponent("stats"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try encoder.encode(envelope)

        await setStatus(.working("上傳密文中⋯"))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.network("沒有收到有效回應")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncError.server(http.statusCode,
                                       String(data: data, encoding: .utf8) ?? "")
            }
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Keys.lastSync)
            await MainActor.run {
                self.lastSyncAt = now
                self.status = .success("已上傳（伺服器只存密文）")
            }
        } catch let error as SyncError {
            await setStatus(.failure(error.localizedDescription))
            throw error
        } catch {
            await setStatus(.failure(error.localizedDescription))
            throw SyncError.network(error.localizedDescription)
        }
    }

    // MARK: 下載

    /// 從伺服器拉回密文再用 Key A 解密；金鑰不對就會解密失敗，這是預期行為。
    func fetchLatest() async throws -> StatsPacket {
        guard enabled else { throw SyncError.notConfigured }
        guard let base = resolvedBaseURL else {
            throw baseURLText.isEmpty ? SyncError.notConfigured : SyncError.insecureURL
        }
        guard let key = DataKeyManager.shared.currentKey() else { throw SyncError.noKey }

        await setStatus(.working("下載密文中⋯"))
        var request = URLRequest(url: base.appendingPathComponent("stats")
            .appending(queryItems: [URLQueryItem(name: "device",
                                                 value: DataKeyManager.shared.deviceIdentifier)]))
        request.httpMethod = "GET"
        applyAuth(to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.network("沒有收到有效回應")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncError.server(http.statusCode,
                                       String(data: data, encoding: .utf8) ?? "")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(EncryptedEnvelope.self, from: data)
            let payload = CryptoBox.SealedPayload(version: envelope.version,
                                                  iv: envelope.iv,
                                                  ciphertext: envelope.ciphertext)
            let packet = try CryptoBox.decrypt(payload, as: StatsPacket.self, key: key)
            await setStatus(.success("已下載並在本機解密完成"))
            return packet
        } catch let error as SyncError {
            await setStatus(.failure(error.localizedDescription))
            throw error
        } catch let error as CryptoBox.CryptoError {
            await setStatus(.failure(error.localizedDescription))
            throw error
        } catch {
            await setStatus(.failure(error.localizedDescription))
            throw SyncError.network(error.localizedDescription)
        }
    }

    // MARK: 本機自我測試（沒有伺服器也能驗證加解密是通的）

    func selfTest() -> String {
        guard let key = DataKeyManager.shared.currentKey() else {
            return "尚未建立金鑰"
        }
        let sample = StatsPacket(generatedAt: Date(), totalWorkouts: 12,
                                 totalDistance: 84_300, totalDuration: 30_600,
                                 totalCalories: 6_200, weeklyDistance: 21_000,
                                 weeklyDuration: 7_800, longestDistance: 21_097,
                                 bestPace: 312, currentStreak: 4,
                                 byType: ["gpsRun": 8, "walk": 4])
        do {
            let sealed = try CryptoBox.encrypt(sample, key: key)
            let restored = try CryptoBox.decrypt(sealed, as: StatsPacket.self, key: key)
            let ok = restored.totalWorkouts == sample.totalWorkouts
                && restored.totalDistance == sample.totalDistance
            let size = (Data(base64Encoded: sealed.ciphertext)?.count ?? 0)
            return ok ? "通過：加密 \(size) bytes，解密後資料一致" : "失敗：解密結果不一致"
        } catch {
            return "失敗：\(error.localizedDescription)"
        }
    }

    /// 刪除伺服器上這支裝置的全部密文
    func wipeServerData() async throws {
        guard let base = resolvedBaseURL else {
            throw baseURLText.isEmpty ? SyncError.notConfigured : SyncError.insecureURL
        }
        var request = URLRequest(url: base.appendingPathComponent("stats")
            .appending(queryItems: [URLQueryItem(name: "device",
                                                 value: DataKeyManager.shared.deviceIdentifier)]))
        request.httpMethod = "DELETE"
        applyAuth(to: &request)

        await setStatus(.working("刪除伺服器資料中⋯"))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.network("沒有收到有效回應")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            await setStatus(.success("伺服器上的密文已全部刪除"))
        } catch let error as SyncError {
            await setStatus(.failure(error.localizedDescription))
            throw error
        } catch {
            await setStatus(.failure(error.localizedDescription))
            throw SyncError.network(error.localizedDescription)
        }
    }

    /// 測試伺服器是否活著（打 /health，不需要授權）
    func ping() async -> String {
        guard let base = resolvedBaseURL else {
            return baseURLText.isEmpty ? "尚未填寫伺服器位址" : "位址無效：只接受 HTTPS"
        }
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "沒有收到有效回應" }
            return (200..<300).contains(http.statusCode)
                ? "連線正常（HTTP \(http.statusCode)）"
                : "伺服器回應 HTTP \(http.statusCode)"
        } catch {
            return "連不上：\(error.localizedDescription)"
        }
    }

    private func applyAuth(to request: inout URLRequest) {
        guard !accessToken.isEmpty else { return }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }

    @MainActor
    private func setStatus(_ value: Status) {
        status = value
    }
}
