import Foundation
import CryptoKit

/// 統計資料的加解密核心。演算法固定 AES-256-GCM
/// （比 CBC 多一層完整性驗證，資料被竄改會直接解密失敗）。
enum CryptoBox {

    enum CryptoError: LocalizedError {
        case sealFailed
        case openFailed
        case badPayload

        var errorDescription: String? {
            switch self {
            case .sealFailed: return "加密失敗"
            case .openFailed: return "解密失敗：金鑰不符或資料已被竄改"
            case .badPayload: return "資料格式不正確"
            }
        }
    }

    /// 密文封包：IV（nonce）與密文本體分開存，方便對照規劃書的資料格式
    struct SealedPayload: Codable {
        /// 格式版本號，之後換演算法時用來相容舊資料
        var version: Int = 1
        /// 初始化向量（Base64）
        let iv: String
        /// 密文本體＋驗證標籤（Base64）
        let ciphertext: String

        var combined: Data? {
            guard let ivData = Data(base64Encoded: iv),
                  let body = Data(base64Encoded: ciphertext) else { return nil }
            return ivData + body
        }
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> SealedPayload {
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else {
            throw CryptoError.sealFailed
        }
        let body = sealed.ciphertext + sealed.tag
        return SealedPayload(iv: Data(nonce).base64EncodedString(),
                             ciphertext: body.base64EncodedString())
    }

    static func decrypt(_ payload: SealedPayload, key: SymmetricKey) throws -> Data {
        guard let ivData = Data(base64Encoded: payload.iv),
              let body = Data(base64Encoded: payload.ciphertext),
              body.count > 16 else {
            throw CryptoError.badPayload
        }
        do {
            let nonce = try AES.GCM.Nonce(data: ivData)
            let tag = body.suffix(16)
            let cipher = body.prefix(body.count - 16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.openFailed
        }
    }

    /// 便利版本：直接對 Encodable 物件加密
    static func encrypt<T: Encodable>(_ value: T, key: SymmetricKey) throws -> SealedPayload {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encrypt(encoder.encode(value), key: key)
    }

    static func decrypt<T: Decodable>(_ payload: SealedPayload, as type: T.Type, key: SymmetricKey) throws -> T {
        let data = try decrypt(payload, key: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
