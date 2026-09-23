import Foundation

/// A value that the platform may or may not expose.
///
/// ChaiNet never fabricates data: when iOS does not provide something (cellular band, RSRP,
/// Wi-Fi RSSI, …) the value is `.unavailable` with a human-readable reason that the UI shows.
public enum Availability<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case available(Value)
    case unavailable(reason: String)

    public var value: Value? {
        if case .available(let v) = self { return v }
        return nil
    }

    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Standard reasons, so the wording is consistent across the app.
public enum UnavailableReason {
    public static let cellularRadioMetrics =
        "iOS 不開放第三方 App 讀取行動網路訊號資訊（RSRP、RSRQ、SINR、頻段、Cell ID）。"
    public static let wifiSignal =
        "iOS 僅允許具備 NEHotspotHelper 特殊授權的 App 讀取 Wi-Fi RSSI。"
    public static let wifiSSID =
        "需要「Access Wi-Fi Information」授權與定位權限（未簽名版本無此授權）。"
    public static let carrierName =
        "CTCarrier 自 iOS 16 起已停用，只會回傳佔位值。"
    public static let notOnCellular = "目前未使用行動網路。"
    public static let notOnWiFi = "目前未使用 Wi-Fi。"
    public static let notMeasured = "本次未量測。"
    public static let serverUnsupported = "所選伺服器不支援此項量測。"
}
