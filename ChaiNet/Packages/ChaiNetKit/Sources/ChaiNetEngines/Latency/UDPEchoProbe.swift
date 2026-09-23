import Foundation
import Network
import ChaiNetCore

/// UDP echo against the ChaiNet backend's echo port. The only probe that sees real packet loss
/// on the path to the test server (TCP would hide it by retransmitting).
///
/// Packet layout (big-endian): "CHNT" magic (4) | sequence UInt32 (4) | padding to `payloadSize`.
public final class UDPEchoProbe: LatencyProbe, @unchecked Sendable {
    public static let magic: [UInt8] = Array("CHNT".utf8)

    public let host: String
    public let port: UInt16
    public let payloadSize: Int
    public let method: EndpointProbeMethod = .udpEcho
    public var targetDescription: String { "udp://\(host):\(port)" }

    private let pending = PendingProbes()
    private let connection = LockedValue<NWConnection?>(nil)

    public init(host: String, port: UInt16, payloadSize: Int = 64, ipVersion: NWProtocolIP.Options.Version? = nil) {
        self.host = host
        self.port = port
        self.payloadSize = max(8, payloadSize)
        self.ipVersion = ipVersion
    }

    private let ipVersion: NWProtocolIP.Options.Version?

    public func prepare() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw EngineError.unsupported("port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWAsync.parameters(tcp: false, ipVersion: ipVersion))
        try await NWAsync.connect(conn, timeout: 5)
        connection.withLock { $0 = conn }
        receiveNext(conn)
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            let now = ContinuousClock.now
            if let data, data.count >= 8, Array(data.prefix(4)) == Self.magic {
                let bytes = [UInt8](data)
                let seq = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
                self.pending.resolve(sequence: seq, at: now)
            }
            if error == nil, conn.state == .ready { self.receiveNext(conn) }
        }
    }

    static func packet(sequence: UInt32, size: Int) -> Data {
        var bytes = magic
        bytes += [UInt8(sequence >> 24), UInt8(truncatingIfNeeded: sequence >> 16), UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        if size > bytes.count { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
        return Data(bytes)
    }

    public func probe(sequence: Int, timeout: Double) async -> Double? {
        guard let conn = connection.current else { return nil }
        let seq = UInt32(truncatingIfNeeded: sequence)
        let data = Self.packet(sequence: seq, size: payloadSize)
        return await pending.waitForReply(sequence: seq, timeout: timeout) {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    public func close() async {
        pending.expireAll()
        connection.withLock { $0?.cancel(); $0 = nil }
    }
}
