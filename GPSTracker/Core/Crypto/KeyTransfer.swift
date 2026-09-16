import Foundation
import CryptoKit
import CommonCrypto

/// 金鑰匯出／匯入模組（規劃書方案 A）。
/// 使用者自訂密碼 → PBKDF2 衍生金鑰 → 再用 AES-256-GCM 把 Key A 包一層才寫成檔案。
enum KeyTransfer {

    /// 匯出檔結構，完全對應規劃書第四節
    struct KeyEnvelope: Codable {
        /// 格式版本號
        var version: Int = 1
        /// 金鑰衍生演算法
        var kdf: String = "PBKDF2-HMAC-SHA256"
        /// 迭代次數
        var iterations: Int
        /// Base64 Salt
        var salt: String
        /// Base64 IV
        var iv: String
        /// Base64 加密後的 Key A
        var ciphertext: String
        /// 金鑰指紋，匯入前可以先核對是不是同一把
        var fingerprint: String
        /// 匯出時間
        var exportedAt: Date
    }

    enum TransferError: LocalizedError {
        case weakPassword
        case derivationFailed
        case wrongPassword
        case badFile
        case noKey

        var errorDescription: String? {
            switch self {
            case .weakPassword: return "密碼至少要 8 個字元"
            case .derivationFailed: return "金鑰衍生失敗"
            case .wrongPassword: return "密碼不正確，或檔案已損毀"
            case .badFile: return "這不是有效的金鑰匯出檔"
            case .noKey: return "這支手機還沒有資料金鑰"
            }
        }
    }

    /// 規劃書要求 10 萬輪以上；這裡用 OWASP 目前建議的 210,000 輪
    static let defaultIterations = 210_000

    // MARK: 匯出

    static func export(key: SymmetricKey, password: String,
                       iterations: Int = defaultIterations) throws -> KeyEnvelope {
        guard password.count >= 8 else { throw TransferError.weakPassword }

        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            }
        }

        let wrapping = try derive(password: password, salt: salt, iterations: iterations)
        let keyData = key.withUnsafeBytes { Data($0) }
        let sealed = try CryptoBox.encrypt(keyData, key: wrapping)

        return KeyEnvelope(iterations: iterations,
                           salt: salt.base64EncodedString(),
                           iv: sealed.iv,
                           ciphertext: sealed.ciphertext,
                           fingerprint: DataKeyManager.fingerprint(of: keyData),
                           exportedAt: Date())
    }

    static func encode(_ envelope: KeyEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// 寫成可以分享出去的 .gtkey 檔
    static func writeFile(_ envelope: KeyEnvelope) throws -> URL {
        let data = try encode(envelope)
        let name = "軌跡記錄器金鑰-\(Int(envelope.exportedAt.timeIntervalSince1970)).gtkey"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: 匯入

    static func decode(_ data: Data) throws -> KeyEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(KeyEnvelope.self, from: data) else {
            throw TransferError.badFile
        }
        return envelope
    }

    static func importKey(from envelope: KeyEnvelope, password: String) throws -> SymmetricKey {
        guard let salt = Data(base64Encoded: envelope.salt) else { throw TransferError.badFile }
        let wrapping = try derive(password: password,
                                  salt: salt,
                                  iterations: envelope.iterations)
        let payload = CryptoBox.SealedPayload(version: envelope.version,
                                              iv: envelope.iv,
                                              ciphertext: envelope.ciphertext)
        guard let keyData = try? CryptoBox.decrypt(payload, key: wrapping) else {
            throw TransferError.wrongPassword
        }
        return SymmetricKey(data: keyData)
    }

    // MARK: PBKDF2

    static func derive(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)

        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordData.map { Int8(bitPattern: $0) },
                                        passwordData.count,
                                        saltBase,
                                        salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                        UInt32(iterations),
                                        &derived,
                                        derived.count)
        }
        guard status == kCCSuccess else { throw TransferError.derivationFailed }
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
