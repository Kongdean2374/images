import Foundation
import ChaiNetCore
#if canImport(Darwin)
import Darwin
#endif

/// Unprivileged ICMP datagram socket (`SOCK_DGRAM` + `IPPROTO_ICMP`), which Darwin allows
/// without root — the same mechanism as Apple's SimplePing sample. IPv4 only.
///
/// Limitation: some networks filter ICMP, and ICMP may be rate-limited / de-prioritised by
/// routers, so ICMP RTTs can be higher than application traffic.
public final class ICMPSocket: @unchecked Sendable {
    public let fd: Int32
    private let closed = LockedValue(false)

    public init() throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard s >= 0 else { throw EngineError.socket("socket(): \(String(cString: strerror(errno)))") }
        fd = s
    }

    deinit { close() }

    public func setTTL(_ ttl: Int32) throws {
        var value = ttl
        guard setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw EngineError.socket("IP_TTL: \(String(cString: strerror(errno)))")
        }
    }

    /// Sets the IPv4 Don't-Fragment bit (`IP_DONTFRAG`, value 28 on Darwin).
    public func setDontFragment(_ on: Bool) throws {
        var value: Int32 = on ? 1 : 0
        guard setsockopt(fd, IPPROTO_IP, 28, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw EngineError.socket("IP_DONTFRAG: \(String(cString: strerror(errno)))")
        }
    }

    /// Sends to an IPv4 literal. Returns errno on failure (EMSGSIZE = larger than local MTU with DF).
    @discardableResult
    public func send(_ bytes: [UInt8], to ipv4: String) -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, ipv4, &addr.sin_addr) == 1 else { return EINVAL }
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    /// Blocking receive with timeout (poll). Returns the datagram (IP header included) and the
    /// source address. Call from a background thread only.
    public func receive(timeout: Double) -> (bytes: [UInt8], source: String)? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(max(0, timeout * 1000)))
        guard ready > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buffer.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
                }
            }
        }
        guard n > 0 else { return nil }
        let source = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketSupport.numericHost($0, length: len) }
        } ?? ""
        return (Array(buffer.prefix(n)), source)
    }

    public var isClosed: Bool { closed.current }

    public func close() {
        let shouldClose = closed.withLock { c -> Bool in
            if c { return false }
            c = true
            return true
        }
        if shouldClose { Darwin.close(fd) }
    }
}

/// ICMP echo probe with a background receive loop so probes can overlap (fixed-rate tests).
public final class ICMPEchoProbe: LatencyProbe, @unchecked Sendable {
    public let host: String
    public let payloadSize: Int
    public let method: EndpointProbeMethod = .icmpEcho
    public var targetDescription: String { "icmp://\(host)" }

    private let identifier = UInt16.random(in: 1...UInt16.max)
    private let pending = PendingProbes()
    private let state = LockedValue<(socket: ICMPSocket?, address: String?)>((nil, nil))

    public init(host: String, payloadSize: Int = 56) {
        self.host = host
        self.payloadSize = payloadSize
    }

    public func prepare() async throws {
        let address: String
        if SocketSupport.isIPv4Literal(host) {
            address = host
        } else {
            guard let v4 = try await SocketSupport.resolve(host, family: .ipv4).first else { throw EngineError.resolutionFailed(host) }
            address = v4.string
        }
        let socket = try ICMPSocket()
        state.withLock { $0 = (socket, address) }
        let thread = Thread { [weak self] in self?.receiveLoop(socket) }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func receiveLoop(_ socket: ICMPSocket) {
        while !socket.isClosed {
            guard let received = socket.receive(timeout: 0.2) else { continue }
            let now = ContinuousClock.now
            if case .echoReply(let ident, let seq)? = ICMPPacket.parse(received.bytes), ident == identifier {
                pending.resolve(sequence: UInt32(seq), at: now)
            }
        }
    }

    public func probe(sequence: Int, timeout: Double) async -> Double? {
        let (socket, address) = state.current
        guard let socket, let address else { return nil }
        let seq = UInt16(truncatingIfNeeded: sequence)
        let packet = ICMPPacket.makeEchoRequest(identifier: identifier, sequence: seq, payloadSize: payloadSize)
        return await pending.waitForReply(sequence: UInt32(seq), timeout: timeout) {
            socket.send(packet, to: address)
        }
    }

    public func close() async {
        pending.expireAll()
        state.withLock { $0.socket?.close(); $0 = (nil, nil) }
    }
}
