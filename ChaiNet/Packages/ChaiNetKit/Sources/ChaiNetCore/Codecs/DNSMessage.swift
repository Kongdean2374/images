import Foundation

/// Minimal DNS wire-format encoder / decoder (RFC 1035) — enough for resolver benchmarking.
public enum DNSMessage {
    public enum RecordType: UInt16, Sendable {
        case a = 1
        case aaaa = 28
    }

    /// Builds a standard query with recursion desired.
    ///
    /// Header: ID | flags 0x0100 (RD) | QDCOUNT 1 | AN/NS/AR 0; Question: QNAME QTYPE QCLASS(IN).
    public static func makeQuery(id: UInt16, name: String, type: RecordType) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8.prefix(63))
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        bytes.append(contentsOf: [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF), 0x00, 0x01])
        return bytes
    }

    public struct ResponseHeader: Equatable, Sendable {
        public var id: UInt16
        public var isResponse: Bool
        /// 0 NOERROR, 2 SERVFAIL, 3 NXDOMAIN …
        public var rcode: UInt8
        public var answerCount: UInt16
        public var truncated: Bool
    }

    public static func parseHeader(_ bytes: [UInt8]) -> ResponseHeader? {
        guard bytes.count >= 12 else { return nil }
        return ResponseHeader(
            id: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
            isResponse: bytes[2] & 0x80 != 0,
            rcode: bytes[3] & 0x0F,
            answerCount: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
            truncated: bytes[2] & 0x02 != 0)
    }
}
