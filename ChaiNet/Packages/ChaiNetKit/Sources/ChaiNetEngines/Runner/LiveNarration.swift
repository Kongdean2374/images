import Foundation
import ChaiNetCore

/// Display-only live narration for the running-test screen (Traditional Chinese). Measurements
/// are unaffected: these helpers only turn engine progress into `TestRunEvent`s.
enum LiveNarration {
    static func sink(_ phase: TestPhase, _ emit: @escaping @Sendable (TestRunEvent) -> Void) -> LiveSink {
        LiveSink(sample: { emit(.liveSample(phase, $0, $1)) }, note: { emit(.note(phase, $0)) })
    }

    static func transportName(_ t: DNSTransport) -> String {
        switch t {
        case .system: "系統解析器"
        case .udp: "UDP 53"
        case .doh: "DoH（HTTPS）"
        }
    }

    static func dnsStart(resolvers: Int, domains: Int, emit: @Sendable (TestRunEvent) -> Void) {
        emit(.note(.dns, "查詢 \(domains) 個常用網域，比較 \(resolvers) 個解析器（系統 / UDP / DoH）的回應時間與失敗率"))
    }

    static func dnsResolver(_ r: DNSResolverResult, emit: @Sendable (TestRunEvent) -> Void) {
        let failed = r.samples.filter { $0.rttMs == nil }.count
        if let median = r.statistics.rtt?.median {
            emit(.liveValue(.dns, r.resolver.name, median, "ms"))
            emit(.note(.dns, "\(r.resolver.name)（\(transportName(r.resolver.transport))）：中位數 \(Fmt.d(median, 0)) ms，失敗 \(failed)/\(r.samples.count)"))
        } else {
            emit(.note(.dns, "\(r.resolver.name)（\(transportName(r.resolver.transport))）：全部查詢失敗"))
        }
    }

    static func protocolStart(host: String, emit: @Sendable (TestRunEvent) -> Void) {
        emit(.note(.protocols, "對 \(host) 分段量測：DNS 解析 → TCP 連線 → TLS 交握 → 首位元組（TTFB），並嘗試 HTTP/3 與 QUIC"))
    }

    static func protocolResult(_ p: ProtocolProbeResult, emit: @Sendable (TestRunEvent) -> Void) {
        if let h = p.http {
            let parts: [(String, Double?)] = [("DNS", h.dnsMs), ("TCP", h.tcpConnectMs), ("TLS", h.tlsMs), ("TTFB", h.ttfbMs)]
            for (label, v) in parts { if let v { emit(.liveValue(.protocols, label, v, "ms")) } }
            emit(.note(.protocols, "HTTP 協商為 \(h.negotiatedProtocol.displayName)，TLS \(h.tlsVersion ?? "—")"))
        }
        emit(.note(.protocols, p.http3Negotiated ? "HTTP/3：已協商成功" : "HTTP/3：\(p.host) 未協商（退回 \(p.http3Attempt?.negotiatedProtocol.displayName ?? "TCP")，僅限此端點）"))
        for q in p.quicProbes ?? [] {
            emit(.note(.protocols, q.handshakeMs.map { "QUIC → \(q.host)：交握 \(Fmt.d($0, 0)) ms" } ?? "QUIC → \(q.host)：失敗（\(q.failure?.rawValue ?? "—")）"))
        }
    }

    static func ipFamiliesStart(host: String, emit: @Sendable (TestRunEvent) -> Void) {
        emit(.note(.ipFamilies, "同時以 IPv4 與 IPv6 對 \(host) 建立 TCP 連線，比較兩條路徑的延遲與失敗率"))
    }

    static func ipFamiliesResult(_ f: IPFamilyComparisonResult, emit: @Sendable (TestRunEvent) -> Void) {
        let v4 = (f.ipv4?.rtt?.median).map { "\(Fmt.d($0, 0)) ms" } ?? "無法連線"
        let v6 = (f.ipv6?.rtt?.median).map { "\(Fmt.d($0, 0)) ms" } ?? "無法連線"
        emit(.note(.ipFamilies, "結果：IPv4 \(v4)、IPv6 \(v6)"))
    }

    static func mtuStart(host: String, emit: @Sendable (TestRunEvent) -> Void) {
        emit(.note(.mtu, "以「禁止分段」的 ICMP 封包對 \(host) 二分搜尋最大可通過的封包大小（IPv4）"))
    }

    static func traceStart(host: String, emit: @Sendable (TestRunEvent) -> Void) {
        emit(.note(.traceroute, "逐跳增加 TTL，找出通往 \(host) 的每個路由節點與其回應時間"))
    }
}
