import Foundation

/// Which export is being produced.
///
/// * `aiSafe` (default) — for pasting into AI assistants / sharing: every IPv4 / IPv6 literal
///   (public, local, link-local, tunnel / VPN) becomes `[REDACTED]`. Well-known public resolver
///   anycast addresses the app itself probes (1.1.1.1, 8.8.8.8 …) are kept, since they identify
///   nobody and are needed to read the results.
/// * `engineer` — complete raw data; full IPs only when explicitly requested.
public struct ExportPrivacy: Sendable, Hashable {
    public enum Profile: String, Sendable, Hashable { case aiSafe, engineer }
    public var profile: Profile
    public var includeIPs: Bool

    public static let aiSafe = ExportPrivacy(profile: .aiSafe, includeIPs: false)
    public static func engineer(includeIPs: Bool) -> ExportPrivacy { ExportPrivacy(profile: .engineer, includeIPs: includeIPs) }

    public var redactsIPs: Bool { !(profile == .engineer && includeIPs) }
    public var summary: String {
        redactsIPs
            ? "\(profile.rawValue); ip_addresses=[REDACTED] (public, local, link-local, tunnel); well-known public resolver anycast addresses kept"
            : "\(profile.rawValue); ip_addresses=full (user opted in)"
    }
}

public enum IPRedactor {
    public static let placeholder = "[REDACTED]"

    /// Public anycast service addresses probed by the app; not personal data.
    public static let wellKnownPublic: Set<String> = [
        "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220",
        "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888", "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9",
    ]

    // Octet 0–255; not part of a longer dotted number (so "2.1.0" or "1.2.3.4.5" are left alone).
    private static let octet = "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
    private static let ipv4 = try! NSRegularExpression(pattern: "(?<![0-9.])(?:\(octet)\\.){3}\(octet)(?![0-9]|\\.[0-9])")
    // IPv6 candidates (≥ 2 colons, optional embedded IPv4 and zone); validated by `isIPv6`.
    private static let ipv6Candidate = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:(?<=:)(?:[0-9]{1,3}\\.){3}[0-9]{1,3})?(?:%[0-9A-Za-z_.-]+)?(?![0-9A-Za-z:.])")

    public static func redact(_ text: String) -> String {
        var out = replace(ipv6Candidate, in: text) { isIPv6($0) }
        out = replace(ipv4, in: out) { _ in true }
        return out
    }

    /// Strict IPv6 syntax check (RFC 4291 text forms, optional zone and trailing IPv4).
    public static func isIPv6(_ s: String) -> Bool {
        var body = Substring(s)
        if let pct = body.firstIndex(of: "%") { body = body[..<pct] }
        let halves = body.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        func groups(_ part: String) -> Int? {
            if part.isEmpty { return 0 }
            var n = 0
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            for (i, p) in pieces.enumerated() {
                if i == pieces.count - 1, p.contains(".") {
                    let o = p.split(separator: ".", omittingEmptySubsequences: false)
                    guard o.count == 4, o.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
                    n += 2
                } else {
                    guard (1...4).contains(p.count), p.allSatisfy(\.isHexDigit) else { return nil }
                    n += 1
                }
            }
            return n
        }
        if halves.count == 1 { return groups(halves[0]) == 8 }
        guard let a = groups(halves[0]), let b = groups(halves[1]) else { return false }
        return a + b <= 7
    }

    private static func replace(_ re: NSRegularExpression, in text: String, when valid: (String) -> Bool) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            let bare = token.split(separator: "%").first.map(String.init) ?? token
            guard valid(token), !wellKnownPublic.contains(bare.lowercased()) else { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + placeholder
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
