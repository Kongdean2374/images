import Foundation
import ChaiNetCore

public protocol TracerouteEngineProtocol: Sendable {
    func run(host: String, maxHops: Int, probesPerHop: Int, onHop: @escaping @Sendable (TracerouteHop) -> Void) async throws -> TracerouteResult
}

public protocol MTUDiscoveryEngineProtocol: Sendable {
    func run(host: String) async throws -> MTUResult
    /// Same measurement, describing each probed packet size to `live`.
    func run(host: String, live: LiveSink) async throws -> MTUResult
}

extension MTUDiscoveryEngineProtocol {
    public func run(host: String, live: LiveSink) async throws -> MTUResult { try await run(host: host) }
}

/// ICMP traceroute (IPv4): echo requests with increasing TTL; routers answer "time exceeded",
/// the destination answers "echo reply".
///
/// Limitation: IPv6 hop discovery (ICMPv6 + IPV6_UNICAST_HOPS) is not implemented yet; hops
/// that filter ICMP appear as "*" — that does not mean packets are lost there.
public struct ICMPTracerouteEngine: TracerouteEngineProtocol {
    public init() {}

    public func run(host: String, maxHops: Int = 30, probesPerHop: Int = 3,
                    onHop: @escaping @Sendable (TracerouteHop) -> Void) async throws -> TracerouteResult {
        let address: String
        if SocketSupport.isIPv4Literal(host) {
            address = host
        } else {
            guard let a = try await SocketSupport.resolve(host, family: .ipv4).first else { throw EngineError.resolutionFailed(host) }
            address = a.string
        }
        let socket = try ICMPSocket()
        defer { socket.close() }
        let identifier = UInt16.random(in: 1...UInt16.max)
        var hops: [TracerouteHop] = []
        var reached = false
        var sequence: UInt16 = 0

        for ttl in 1...max(1, maxHops) {
            try Task.checkCancellation()
            try socket.setTTL(Int32(ttl))
            var rtts: [Double?] = []
            var hopAddress: String?
            var isDestination = false
            for _ in 0..<probesPerHop {
                sequence &+= 1
                let seq = sequence
                let reply = try await Self.probe(socket: socket, address: address, identifier: identifier, sequence: seq, timeout: 1.5)
                rtts.append(reply?.ms)
                if let reply {
                    hopAddress = hopAddress ?? reply.from
                    if reply.isEchoReply { isDestination = true }
                }
            }
            var hostname: String?
            if let hopAddress {
                hostname = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                    DispatchQueue.global().async { c.resume(returning: SocketSupport.reverseLookupBlocking(ipv4: hopAddress)) }
                }
            }
            let hop = TracerouteHop(ttl: ttl, address: hopAddress, hostname: hostname, rttsMs: rtts, reachedDestination: isDestination)
            hops.append(hop)
            onHop(hop)
            if isDestination { reached = true; break }
        }
        return TracerouteResult(date: Date(), target: host, resolvedAddress: address, hops: hops, reachedDestination: reached,
                                method: "ICMP echo, TTL 1–\(maxHops), \(probesPerHop) probes/hop (IPv4)")
    }

    struct Reply: Sendable { var ms: Double; var from: String; var isEchoReply: Bool }

    /// Sends one probe and waits for the matching time-exceeded / echo-reply (blocking read on a
    /// background queue; cancellation closes nothing but stops waiting at the timeout).
    static func probe(socket: ICMPSocket, address: String, identifier: UInt16, sequence: UInt16, timeout: Double) async throws -> Reply? {
        try Task.checkCancellation()
        return await withCheckedContinuation { (cont: CheckedContinuation<Reply?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let packet = ICMPPacket.makeEchoRequest(identifier: identifier, sequence: sequence, payloadSize: 32)
                let stopwatch = Stopwatch()
                guard socket.send(packet, to: address) == 0 else { return cont.resume(returning: nil) }
                while stopwatch.elapsed < timeout {
                    guard let r = socket.receive(timeout: timeout - stopwatch.elapsed) else { break }
                    switch ICMPPacket.parse(r.bytes) {
                    case .echoReply(let id, let seq)? where id == identifier && seq == sequence:
                        return cont.resume(returning: Reply(ms: stopwatch.elapsedMs, from: r.source, isEchoReply: true))
                    case .timeExceeded(let id, let seq)? where id == identifier && seq == sequence:
                        return cont.resume(returning: Reply(ms: stopwatch.elapsedMs, from: r.source, isEchoReply: false))
                    case .unreachable(_, let id, let seq, _)? where id == identifier && seq == sequence:
                        return cont.resume(returning: Reply(ms: stopwatch.elapsedMs, from: r.source, isEchoReply: true))
                    default:
                        continue
                    }
                }
                cont.resume(returning: nil)
            }
        }
    }
}

/// Path-MTU discovery with ICMP echo + Don't-Fragment, binary search over IP packet sizes.
///
///     packet size = 20 (IPv4 header) + 8 (ICMP header) + payload
///     search range [576, 1500]; a size "passes" when any of 2 attempts gets an echo reply.
///
/// EMSGSIZE from `sendto` means the local interface MTU is smaller; "fragmentation needed"
/// replies carry the next-hop MTU. Silent drops (PMTU black holes) look like failures.
public struct ICMPMTUDiscoveryEngine: MTUDiscoveryEngineProtocol {
    public init() {}

    public func run(host: String) async throws -> MTUResult { try await run(host: host, live: .none) }

    public func run(host: String, live: LiveSink) async throws -> MTUResult {
        let address: String
        if SocketSupport.isIPv4Literal(host) {
            address = host
        } else {
            guard let a = try await SocketSupport.resolve(host, family: .ipv4).first else { throw EngineError.resolutionFailed(host) }
            address = a.string
        }
        let socket = try ICMPSocket()
        defer { socket.close() }
        try socket.setDontFragment(true)
        let identifier = UInt16.random(in: 1...UInt16.max)
        var sequence: UInt16 = 0
        var probes: [MTUProbe] = []

        func test(_ size: Int) async throws -> Bool {
            let payload = size - 28
            for _ in 0..<2 {
                try Task.checkCancellation()
                sequence &+= 1
                let seq = sequence
                let outcome = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let packet = ICMPPacket.makeEchoRequest(identifier: identifier, sequence: seq, payloadSize: payload)
                        let err = socket.send(packet, to: address)
                        if err == EMSGSIZE { return cont.resume(returning: (false, "超過本機介面 MTU（EMSGSIZE）")) }
                        if err != 0 { return cont.resume(returning: (false, "sendto errno \(err)")) }
                        let stopwatch = Stopwatch()
                        while stopwatch.elapsed < 1.5 {
                            guard let r = socket.receive(timeout: 1.5 - stopwatch.elapsed) else { break }
                            switch ICMPPacket.parse(r.bytes) {
                            case .echoReply(let id, let s)? where id == identifier && s == seq:
                                return cont.resume(returning: (true, nil))
                            case .unreachable(4, let id, let s, let mtu)? where id == identifier && s == seq:
                                return cont.resume(returning: (false, "需要分段，下一跳 MTU \(mtu.map(String.init) ?? "?")"))
                            default: continue
                            }
                        }
                        cont.resume(returning: (false, "無回應"))
                    }
                }
                if outcome.0 {
                    probes.append(MTUProbe(packetSize: size, succeeded: true, note: nil))
                    live.note("\(size) bytes（禁止分段）：通過")
                    return true
                }
                if outcome.1?.contains("EMSGSIZE") == true || outcome.1?.contains("MTU") == true {
                    probes.append(MTUProbe(packetSize: size, succeeded: false, note: outcome.1))
                    live.note("\(size) bytes（禁止分段）：\(outcome.1 ?? "失敗")")
                    return false
                }
                if size == 576 || probes.count > 40 { probes.append(MTUProbe(packetSize: size, succeeded: false, note: outcome.1)); return false }
            }
            probes.append(MTUProbe(packetSize: size, succeeded: false, note: "兩次皆無回應"))
            live.note("\(size) bytes（禁止分段）：無回應")
            return false
        }

        guard try await test(576) else {
            return MTUResult(date: Date(), target: host, pathMTU: nil, probes: probes, method: "ICMP + DF（IPv4）；目標可能過濾 ICMP")
        }
        if try await test(1500) {
            return MTUResult(date: Date(), target: host, pathMTU: 1500, probes: probes, method: "ICMP + DF（IPv4）")
        }
        var low = 576, high = 1500
        while high - low > 1 {
            let mid = (low + high) / 2
            if try await test(mid) { low = mid } else { high = mid }
        }
        return MTUResult(date: Date(), target: host, pathMTU: low, probes: probes, method: "ICMP + DF 二分搜尋（IPv4）")
    }
}
