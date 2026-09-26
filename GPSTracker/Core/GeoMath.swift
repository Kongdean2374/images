import Foundation
import CoreLocation

/// 地理與運動數學工具。
enum GeoMath {
    static let earthRadius: Double = 6_371_000

    /// Haversine 距離（公尺）
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// 兩點間方位角（度，0 = 正北）
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// 秒/公里 轉 公尺/秒
    static func speed(fromPace pace: Double) -> Double {
        pace > 0 ? 1000.0 / pace : 0
    }

    /// 公尺/秒 轉 秒/公里
    static func pace(fromSpeed speed: Double) -> Double? {
        speed > 0.2 ? 1000.0 / speed : nil
    }
}

/// 一維自適應卡爾曼濾波器（Stochastic Models 常用的 GPS 平滑法）。
/// 以測量精度（accuracy）作為觀測雜訊，逐點平滑經緯度與海拔。
final class GPSKalmanFilter {
    /// 預期移動速度（公尺/秒），決定製程雜訊大小。
    ///
    /// 這個值要跟實際移動速度相稱：太小的話濾波器會「跟不上」，
    /// 平滑後的座標一直落在真實位置後方，騎車時軌跡看起來就會整條偏掉。
    /// 因此改成可隨當下速度調整，而不是固定給跑步用的數值。
    private var processNoise: Double
    private var variance: Double = -1
    private var latitude: Double = 0
    private var longitude: Double = 0
    private var altitude: Double = 0
    private var timestamp: TimeInterval = 0

    init(processNoise: Double = 1.6) {
        self.processNoise = processNoise
    }

    func reset() {
        variance = -1
    }

    /// 依當下速度調整製程雜訊。走路跑步維持原本的靈敏度，
    /// 單車等高速活動要放大，濾波器才跟得上。
    func adapt(toSpeed speed: Double) {
        let target = max(1.6, min(12.0, speed * 1.3))
        // 平滑變動，避免忽大忽小
        processNoise = processNoise * 0.8 + target * 0.2
    }

    /// 回傳平滑後的座標與海拔。
    func process(latitude lat: Double,
                 longitude lon: Double,
                 altitude alt: Double,
                 accuracy: Double,
                 timestamp ts: TimeInterval) -> (latitude: Double, longitude: Double, altitude: Double) {
        let acc = max(accuracy, 1.0)
        if variance < 0 {
            timestamp = ts
            latitude = lat
            longitude = lon
            altitude = alt
            variance = acc * acc
        } else {
            let dt = ts - timestamp
            if dt > 0 {
                variance += dt * processNoise * processNoise
                timestamp = ts
            }
            let k = variance / (variance + acc * acc)
            latitude += k * (lat - latitude)
            longitude += k * (lon - longitude)
            altitude += k * (alt - altitude)
            variance = (1 - k) * variance
        }
        return (latitude, longitude, altitude)
    }
}
