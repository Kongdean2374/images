import Foundation
import CryptoKit
import CommonCrypto

/// 備份檔的密碼保護。完全在本機運作，沒有伺服器、沒有帳號、不連網。
/// 密碼 → PBKDF2-HMAC-SHA256 衍生金鑰 → AES-256-GCM 加密整份備份。
enum BackupCrypto {

    /// 加密備份檔的外層結構
    struct Envelope: Codable {
        /// 格式版本號，之後換演算法時用來相容舊檔
        var version: Int = 1
        /// 金鑰衍生演算法
        var kdf: String = "PBKDF2-HMAC-SHA256"
        /// 迭代次數
        var iterations: Int
        /// Base64 Salt
        var salt: String
        /// Base64 IV
        var iv: String
        /// Base64 密文（整份備份 JSON）
        var ciphertext: String
        /// 建立時間
        var createdAt: Date
        /// 固定字串，用來辨識這是加密備份檔
        var format: String = "gpstracker-encrypted-backup"
    }

    enum CryptoError: LocalizedError {
        case weakPassword
        case derivationFailed
        case wrongPassword
        case badFile

        var errorDescription: String? {
            switch self {
            case .weakPassword: return "密碼至少要 8 個字元"
            case .derivationFailed: return "金鑰衍生失敗"
            case .wrongPassword: return "密碼不正確，或檔案已損毀"
            case .badFile: return "這不是有效的加密備份檔"
            }
        }
    }

    /// OWASP 目前建議的迭代次數
    static let iterations = 210_000

    // MARK: 加密

    static func seal(_ plaintext: Data, password: String) throws -> Envelope {
        guard password.count >= 8 else { throw CryptoError.weakPassword }

        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            }
        }

        let key = try derive(password: password, salt: salt, iterations: iterations)
        let sealed = try CryptoBox.encrypt(plaintext, key: key)

        return Envelope(iterations: iterations,
                        salt: salt.base64EncodedString(),
                        iv: sealed.iv,
                        ciphertext: sealed.ciphertext,
                        createdAt: Date())
    }

    static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    // MARK: 解密

    /// 判斷這份檔案是不是加密備份（而不是一般的 JSON 備份）
    static func envelope(in data: Data) -> Envelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.format == "gpstracker-encrypted-backup" else { return nil }
        return envelope
    }

    static func open(_ envelope: Envelope, password: String) throws -> Data {
        guard let salt = Data(base64Encoded: envelope.salt) else { throw CryptoError.badFile }
        let key = try derive(password: password, salt: salt, iterations: envelope.iterations)
        let payload = CryptoBox.SealedPayload(version: envelope.version,
                                              iv: envelope.iv,
                                              ciphertext: envelope.ciphertext)
        guard let plaintext = try? CryptoBox.decrypt(payload, key: key) else {
            throw CryptoError.wrongPassword
        }
        return plaintext
    }

    // MARK: PBKDF2

    static func derive(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)

        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.map { Int8(bitPattern: $0) },
                                        passwordBytes.count,
                                        saltBase,
                                        salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                        UInt32(iterations),
                                        &derived,
                                        derived.count)
        }
        guard status == kCCSuccess else { throw CryptoError.derivationFailed }
        return SymmetricKey(data: Data(derived))
    }

    /// 密碼強度粗略評分（0–1），純本地判斷，只用來給 UI 顯示
    static func passwordStrength(_ password: String) -> Double {
        var score = 0.0
        if password.count >= 8 { score += 0.25 }
        if password.count >= 12 { score += 0.2 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { score += 0.15 }
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 0.1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 0.15 }
        if password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { score += 0.15 }
        return min(1, score)
    }
}
