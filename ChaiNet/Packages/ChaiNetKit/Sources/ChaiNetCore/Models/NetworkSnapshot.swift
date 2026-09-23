import Foundation

public enum InterfaceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
    case none

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .cellular: "行動網路"
        case .wiredEthernet: "有線網路"
        case .loopback: "本機迴路"
        case .other: "其他"
        case .none: "離線"
        }
    }
}

public enum PathStatus: String, Codable, Sendable, Hashable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Radio access technology as reported by CoreTelephony (the only cellular detail iOS exposes).
public enum RadioAccessTechnology: String, Codable, Sendable, Hashable, CaseIterable {
    case gprs, edge, wcdma, hsdpa, hsupa, cdma1x, evdo, ehrpd
    case lte
    case nrNSA
    case nr
    case unknown

    public var generationLabel: String {
        switch self {
        case .gprs, .edge, .cdma1x: "2G"
        case .wcdma, .hsdpa, .hsupa, .evdo, .ehrpd: "3G"
        case .lte: "4G LTE"
        case .nrNSA: "5G NSA"
        case .nr: "5G SA"
        case .unknown: "未知"
        }
    }
}

/// Cellular signal metrics. On iOS every field is `.unavailable` for App Store apps; the type
/// exists so the UI and exports keep a stable schema and so a future API can be plugged in.
public struct CellularSignalMetrics: Codable, Sendable, Hashable {
    public var band: Availability<String>
    public var rsrp: Availability<Double>
    public var rsrq: Availability<Double>
    public var sinr: Availability<Double>
    public var cellID: Availability<String>

    public static let unavailableOnIOS = CellularSignalMetrics(
        band: .unavailable(reason: UnavailableReason.cellularRadioMetrics),
        rsrp: .unavailable(reason: UnavailableReason.cellularRadioMetrics),
        rsrq: .unavailable(reason: UnavailableReason.cellularRadioMetrics),
        sinr: .unavailable(reason: UnavailableReason.cellularRadioMetrics),
        cellID: .unavailable(reason: UnavailableReason.cellularRadioMetrics))
}

public struct CellularInfo: Codable, Sendable, Hashable {
    public var radioTechnology: Availability<RadioAccessTechnology>
    public var carrierName: Availability<String>
    public var signal: CellularSignalMetrics

    public init(radioTechnology: Availability<RadioAccessTechnology>, carrierName: Availability<String>, signal: CellularSignalMetrics) {
        self.radioTechnology = radioTechnology
        self.carrierName = carrierName
        self.signal = signal
    }
}

public struct WiFiInfo: Codable, Sendable, Hashable {
    public var ssid: Availability<String>
    public var bssid: Availability<String>
    public var rssi: Availability<Double>

    public init(ssid: Availability<String>, bssid: Availability<String>, rssi: Availability<Double>) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
    }
}

/// VPN detection is heuristic on iOS (there is no public "is a VPN active" API).
public struct VPNDetection: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        case detected
        case notDetected
        case unknown
    }

    public var state: State
    /// Interfaces that triggered the detection (e.g. `utun4`, `ipsec0`).
    public var interfaces: [String]
    /// How the decision was made, shown to the user for transparency.
    public var method: String

    public init(state: State, interfaces: [String], method: String) {
        self.state = state
        self.interfaces = interfaces
        self.method = method
    }
}

public struct InterfaceAddress: Codable, Sendable, Hashable {
    public enum Family: String, Codable, Sendable, Hashable { case ipv4, ipv6 }
    public var interfaceName: String
    public var address: String
    public var family: Family

    public init(interfaceName: String, address: String, family: Family) {
        self.interfaceName = interfaceName
        self.address = address
        self.family = family
    }
}

/// Everything known about the current network path at a point in time.
public struct NetworkSnapshot: Codable, Sendable, Hashable {
    public var capturedAt: Date
    public var status: PathStatus
    public var primaryInterface: InterfaceKind
    public var availableInterfaces: [InterfaceKind]
    /// `NWPath.isExpensive` — cellular or personal hotspot.
    public var isExpensive: Bool
    /// `NWPath.isConstrained` — Low Data Mode.
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var supportsDNS: Bool
    public var localAddresses: [InterfaceAddress]
    public var publicIPv4: Availability<String>
    public var publicIPv6: Availability<String>
    public var vpn: VPNDetection
    public var cellular: CellularInfo?
    public var wifi: WiFiInfo?

    public init(capturedAt: Date, status: PathStatus, primaryInterface: InterfaceKind, availableInterfaces: [InterfaceKind],
                isExpensive: Bool, isConstrained: Bool, supportsIPv4: Bool, supportsIPv6: Bool, supportsDNS: Bool,
                localAddresses: [InterfaceAddress], publicIPv4: Availability<String>, publicIPv6: Availability<String>,
                vpn: VPNDetection, cellular: CellularInfo?, wifi: WiFiInfo?) {
        self.capturedAt = capturedAt
        self.status = status
        self.primaryInterface = primaryInterface
        self.availableInterfaces = availableInterfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.localAddresses = localAddresses
        self.publicIPv4 = publicIPv4
        self.publicIPv6 = publicIPv6
        self.vpn = vpn
        self.cellular = cellular
        self.wifi = wifi
    }

    public static let offline = NetworkSnapshot(
        capturedAt: .distantPast, status: .unsatisfied, primaryInterface: .none, availableInterfaces: [],
        isExpensive: false, isConstrained: false, supportsIPv4: false, supportsIPv6: false, supportsDNS: false,
        localAddresses: [], publicIPv4: .unavailable(reason: UnavailableReason.notMeasured),
        publicIPv6: .unavailable(reason: UnavailableReason.notMeasured),
        vpn: VPNDetection(state: .unknown, interfaces: [], method: "尚未評估"), cellular: nil, wifi: nil)
}
