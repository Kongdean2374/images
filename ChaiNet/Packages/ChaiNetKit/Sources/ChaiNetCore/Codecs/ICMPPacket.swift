import Foundation

/// ICMP (IPv4) echo packet encoding / decoding. Pure byte manipulation so it can be tested
/// without sockets.
public enum ICMPPacket {
    public static let echoRequest: UInt8 = 8
    public static let echoReply: UInt8 = 0
    public static let destinationUnreachable: UInt8 = 3
    public static let timeExceeded: UInt8 = 11
    public static let headerLength = 8
    public static let ipv4HeaderMinimum = 20

    /// RFC 1071 Internet checksum: one's-complement of the one's-complement sum of all 16-bit
    /// big-endian words (odd trailing byte padded with zero).
    ///
    ///     sum = Σ word₁₆ ; while sum > 0xFFFF: sum = (sum & 0xFFFF) + (sum >> 16) ; checksum = ~sum
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Builds an echo request: type 8, code 0, checksum, identifier, sequence, payload.
    public static func makeEchoRequest(identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
        var packet: [UInt8] = [echoRequest, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        let size = max(0, payloadSize)
        packet.reserveCapacity(headerLength + size)
        for i in 0..<size { packet.append(UInt8(truncatingIfNeeded: i)) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    public enum Parsed: Equatable, Sendable {
        /// Echo reply for (identifier, sequence).
        case echoReply(identifier: UInt16, sequence: UInt16)
        /// A router reported TTL expiry for our probe (identifier, sequence).
        case timeExceeded(identifier: UInt16, sequence: UInt16)
        /// Destination unreachable (code 4 = fragmentation needed, carries next-hop MTU).
        case unreachable(code: UInt8, identifier: UInt16, sequence: UInt16, nextHopMTU: UInt16?)
        case other(type: UInt8)
    }

    /// Parses a received datagram. Darwin ICMP datagram sockets deliver the IPv4 header in
    /// front of the ICMP message; `hasIPHeader` handles both shapes.
    public static func parse(_ data: [UInt8], hasIPHeader: Bool = true) -> Parsed? {
        var offset = 0
        if hasIPHeader {
            guard let ihl = ipHeaderLength(data) else { return nil }
            offset = ihl
        }
        guard data.count >= offset + headerLength else { return nil }
        let type = data[offset]
        let code = data[offset + 1]
        switch type {
        case echoReply:
            return .echoReply(identifier: be16(data, offset + 4), sequence: be16(data, offset + 6))
        case timeExceeded, destinationUnreachable:
            // Payload = original IP header + first 8 bytes of the original ICMP message.
            let inner = offset + headerLength
            guard let innerIHL = ipHeaderLength(Array(data[inner...])),
                  data.count >= inner + innerIHL + headerLength else { return .other(type: type) }
            let original = inner + innerIHL
            let ident = be16(data, original + 4), seq = be16(data, original + 6)
            if type == timeExceeded { return .timeExceeded(identifier: ident, sequence: seq) }
            let mtu = code == 4 ? be16(data, offset + 6) : nil
            return .unreachable(code: code, identifier: ident, sequence: seq, nextHopMTU: mtu == 0 ? nil : mtu)
        default:
            return .other(type: type)
        }
    }

    /// Source address of an IPv4 header as dotted quad.
    public static func sourceAddress(_ data: [UInt8]) -> String? {
        guard data.count >= ipv4HeaderMinimum, data[0] >> 4 == 4 else { return nil }
        return "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
    }

    static func ipHeaderLength(_ data: [UInt8]) -> Int? {
        guard let first = data.first, first >> 4 == 4 else { return nil }
        let ihl = Int(first & 0x0F) * 4
        guard ihl >= ipv4HeaderMinimum, data.count >= ihl else { return nil }
        return ihl
    }

    static func be16(_ d: [UInt8], _ i: Int) -> UInt16 { UInt16(d[i]) << 8 | UInt16(d[i + 1]) }
}
