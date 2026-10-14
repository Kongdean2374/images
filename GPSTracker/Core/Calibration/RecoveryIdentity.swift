import Foundation

enum RecoveryIdentity {
    /// Legacy snapshots lack UUIDs. This deterministic, non-security identifier
    /// makes saving the same snapshot idempotent without modifying its source file.
    static func id(start: Date, type: String) -> UUID {
        let key = "\(start.timeIntervalSince1970.bitPattern):\(type)"
        var a: UInt64 = 14695981039346656037
        var b: UInt64 = 7809847782465536322
        for byte in key.utf8 {
            a = (a ^ UInt64(byte)) &* 1099511628211
            b = (b ^ UInt64(byte)) &* 14029467366897019727
        }
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (56 - $0 * 8)) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: b >> (56 - $0 * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
