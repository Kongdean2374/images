import Foundation
import Network
import ChaiNetCore
#if canImport(CFNetwork)
import CFNetwork
#endif
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS) && canImport(CoreTelephony)
import CoreTelephony
#endif
#if os(iOS) && canImport(NetworkExtension)
import NetworkExtension
#endif

public protocol NetworkInfoProviding: Sendable {
    /// Current snapshot, including public IPs when `includePublicIP` (contacts Cloudflare's
    /// trace endpoint — the only external request this makes).
    func snapshot(includePublicIP: Bool) async -> NetworkSnapshot
    /// Path updates (interface / status changes) until the consumer stops.
    func pathUpdates() -> AsyncStream<NetworkSnapshot>
}

public struct NetworkInfoProvider: NetworkInfoProviding {
    public init() {}

    public func snapshot(includePublicIP: Bool) async -> NetworkSnapshot {
        let path = await Self.currentPath()
        var snap = Self.makeSnapshot(path)
        if includePublicIP, path.status == .satisfied {
            async let v4 = PublicIPLookup.fetch(family: .ipv4)
            async let v6 = PublicIPLookup.fetch(family: .ipv6)
            snap.publicIPv4 = await v4
            snap.publicIPv6 = await v6
        }
        if snap.primaryInterface == .wifi { snap.wifi = await WiFiInfoReader.read() }
        return snap
    }

    public func pathUpdates() -> AsyncStream<NetworkSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(Self.makeSnapshot(path)) }
            monitor.start(queue: DispatchQueue(label: "chainet.path.updates"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    static func currentPath() async -> NWPath {
        await withCheckedContinuation { (cont: CheckedContinuation<NWPath, Never>) in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                if once.trySet() {
                    monitor.cancel()
                    cont.resume(returning: path)
                }
            }
            monitor.start(queue: DispatchQueue(label: "chainet.path.once"))
        }
    }

    static func kind(_ type: NWInterface.InterfaceType) -> InterfaceKind {
        switch type {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wiredEthernet
        case .loopback: .loopback
        default: .other
        }
    }

    static func makeSnapshot(_ path: NWPath) -> NetworkSnapshot {
        let status: PathStatus = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        let available = path.availableInterfaces.map { kind($0.type) }
        let primary: InterfaceKind
        if path.status != .satisfied {
            primary = .none
        } else if path.usesInterfaceType(.wifi) {
            primary = .wifi
        } else if path.usesInterfaceType(.cellular) {
            primary = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            primary = .wiredEthernet
        } else {
            primary = available.first ?? .other
        }
        let addresses = InterfaceAddresses.read()
        let vpn = VPNDetector.detect(addresses: addresses, pathUsesOther: path.usesInterfaceType(.other))
        return NetworkSnapshot(capturedAt: Date(), status: status, primaryInterface: primary, availableInterfaces: available,
                               isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                               supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6, supportsDNS: path.supportsDNS,
                               localAddresses: addresses.filter { !$0.interfaceName.hasPrefix("lo") },
                               publicIPv4: .unavailable(reason: UnavailableReason.notMeasured),
                               publicIPv6: .unavailable(reason: UnavailableReason.notMeasured),
                               vpn: vpn, cellular: primary == .cellular || available.contains(.cellular) ? CellularInfoReader.read() : nil,
                               wifi: nil)
    }
}

/// Interface addresses via getifaddrs.
public enum InterfaceAddresses {
    public static func read() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var out: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let addr = ifa.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard let s = SocketSupport.numericHost(addr, length: length) else { continue }
            out.append(InterfaceAddress(interfaceName: String(cString: ifa.pointee.ifa_name), address: s,
                                        family: family == AF_INET ? .ipv4 : .ipv6))
        }
        return out
    }
}

/// Heuristic VPN detection (iOS has no public "VPN active" API).
///
/// 1. `CFNetworkCopySystemProxySettings()["__SCOPED__"]` lists interfaces with scoped proxy /
///    routing settings; `utun*`, `ipsec*`, `ppp*`, `tap*`, `tun*` there indicate a VPN.
/// 2. `NWPath.usesInterfaceType(.other)` for the default route.
///
/// iOS always has several idle `utun` interfaces (iCloud Private Relay, system services), so the
/// mere presence of `utun` with an address is **not** treated as a VPN.
public enum VPNDetector {
    static let prefixes = ["utun", "ipsec", "ppp", "tap", "tun"]

    public static func detect(addresses: [InterfaceAddress], pathUsesOther: Bool) -> VPNDetection {
        var scoped: [String] = []
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let dict = settings["__SCOPED__"] as? [String: Any] {
            scoped = dict.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }.sorted()
        }
        if !scoped.isEmpty {
            return VPNDetection(state: .detected, interfaces: scoped, method: "系統 Proxy 設定中的 scoped 介面")
        }
        if pathUsesOther {
            return VPNDetection(state: .detected, interfaces: [], method: "預設路由使用「other」類型介面")
        }
        return VPNDetection(state: .notDetected, interfaces: [], method: "啟發式：未發現 VPN 介面設定")
    }
}

/// Cellular info from CoreTelephony. Only the radio access technology is available; every
/// signal metric is reported as unavailable (never simulated).
public enum CellularInfoReader {
    public static func read() -> CellularInfo {
        #if os(iOS) && canImport(CoreTelephony) && !targetEnvironment(simulator)
        let info = CTTelephonyNetworkInfo()
        let techs = info.serviceCurrentRadioAccessTechnology ?? [:]
        let preferredService = info.dataServiceIdentifier
        let tech = preferredService.flatMap { techs[$0] } ?? techs.values.first
        let rat: Availability<RadioAccessTechnology> = tech.map { .available(map($0)) }
            ?? .unavailable(reason: "CoreTelephony 未回報無線電制式（可能無 SIM 或行動數據關閉）")
        return CellularInfo(radioTechnology: rat, carrierName: .unavailable(reason: UnavailableReason.carrierName), signal: .unavailableOnIOS)
        #else
        return CellularInfo(radioTechnology: .unavailable(reason: "此平台（模擬器 / macOS）沒有 CoreTelephony 行動網路資訊"),
                            carrierName: .unavailable(reason: UnavailableReason.carrierName), signal: .unavailableOnIOS)
        #endif
    }

    #if os(iOS) && canImport(CoreTelephony)
    static func map(_ value: String) -> RadioAccessTechnology {
        if #available(iOS 14.1, *) {
            if value == CTRadioAccessTechnologyNR { return .nr }
            if value == CTRadioAccessTechnologyNRNSA { return .nrNSA }
        }
        switch value {
        case CTRadioAccessTechnologyLTE: return .lte
        case CTRadioAccessTechnologyWCDMA: return .wcdma
        case CTRadioAccessTechnologyHSDPA: return .hsdpa
        case CTRadioAccessTechnologyHSUPA: return .hsupa
        case CTRadioAccessTechnologyEdge: return .edge
        case CTRadioAccessTechnologyGPRS: return .gprs
        case CTRadioAccessTechnologyCDMA1x: return .cdma1x
        case CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB: return .evdo
        case CTRadioAccessTechnologyeHRPD: return .ehrpd
        default: return .unknown
        }
    }
    #endif
}

/// Wi-Fi info. SSID/BSSID need the "Access Wi-Fi Information" entitlement + location
/// permission (not available to unsigned builds); RSSI is never available to regular apps.
public enum WiFiInfoReader {
    public static func read() async -> WiFiInfo {
        let rssi: Availability<Double> = .unavailable(reason: UnavailableReason.wifiSignal)
        #if os(iOS) && canImport(NetworkExtension) && !targetEnvironment(simulator)
        if let network = await NEHotspotNetwork.fetchCurrent() {
            return WiFiInfo(ssid: .available(network.ssid), bssid: .available(network.bssid), rssi: rssi)
        }
        #endif
        return WiFiInfo(ssid: .unavailable(reason: UnavailableReason.wifiSSID), bssid: .unavailable(reason: UnavailableReason.wifiSSID), rssi: rssi)
    }
}

/// Public IP via Cloudflare's `/cdn-cgi/trace` on the family-specific resolver address.
public enum PublicIPLookup {
    public static func fetch(family: InterfaceAddressFamily) async -> Availability<String> {
        let url = URL(string: family == .ipv4 ? "https://1.1.1.1/cdn-cgi/trace" : "https://[2606:4700:4700::1111]/cdn-cgi/trace")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, _) = try await session.data(from: url)
            let text = String(decoding: data, as: UTF8.self)
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) {
                return .available(String(line.dropFirst(3)))
            }
            return .unavailable(reason: "回應中沒有 IP")
        } catch {
            return .unavailable(reason: family == .ipv4 ? "IPv4 無法連線" : "IPv6 無法連線")
        }
    }
}
