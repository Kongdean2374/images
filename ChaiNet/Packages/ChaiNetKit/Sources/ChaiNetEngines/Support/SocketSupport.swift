import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolved IP address.
public struct ResolvedAddress: Sendable, Hashable {
    public var family: InterfaceAddressFamily
    public var string: String
}

public enum InterfaceAddressFamily: Sendable, Hashable {
    case ipv4, ipv6
}

public enum SocketSupport {
    /// Resolves a host with getaddrinfo (blocking — runs on a background queue).
    public static func resolve(_ host: String, family: InterfaceAddressFamily? = nil) async throws -> [ResolvedAddress] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ResolvedAddress], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try resolveBlocking(host, family: family)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public static func resolveBlocking(_ host: String, family: InterfaceAddressFamily?) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = family == .ipv4 ? AF_INET : (family == .ipv6 ? AF_INET6 : AF_UNSPEC)
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw EngineError.resolutionFailed("\(host) (\(String(cString: gai_strerror(status))))")
        }
        defer { freeaddrinfo(first) }
        var out: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let addr = info.pointee.ai_addr, let s = numericHost(addr, length: info.pointee.ai_addrlen) {
                let fam: InterfaceAddressFamily = info.pointee.ai_family == AF_INET6 ? .ipv6 : .ipv4
                let entry = ResolvedAddress(family: fam, string: s)
                if !out.contains(entry) { out.append(entry) }
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    /// Numeric string of a sockaddr (getnameinfo NI_NUMERICHOST).
    public static func numericHost(_ addr: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reverse DNS (PTR) lookup; nil when there is no name. Blocking — call off the main thread.
    public static func reverseLookupBlocking(ipv4 address: String) -> String? {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        return ok == 0 ? String(cString: buffer) : nil
    }

    public static func isIPv4Literal(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    public static func isIPv6Literal(_ s: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, s, &a) == 1
    }
}
