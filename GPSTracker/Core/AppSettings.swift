import Foundation
import SwiftUI

/// 使用者偏好（純本地儲存，不連後端）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("unit") var unitRaw: String = DistanceUnit.metric.rawValue
    @AppStorage("bodyWeight") var bodyWeight: Double = 65
    @AppStorage("lapDistance") var lapDistance: Double = 400
    @AppStorage("voiceCues") var voiceCues: Bool = true
    @AppStorage("hapticCues") var hapticCues: Bool = true
    @AppStorage("autoPause") var autoPause: Bool = true
    @AppStorage("mapPitch") var mapPitch: Double = 55
    @AppStorage("preferDarkMode") var preferDarkMode: Bool = true

    var unit: DistanceUnit {
        get { DistanceUnit(rawValue: unitRaw) ?? .metric }
        set { unitRaw = newValue.rawValue }
    }
}
