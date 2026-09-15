import Foundation
import CoreLocation
import Combine

/// 定位權限與座標來源。定位被拒不會影響模組 B 的任何功能。
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var horizontalAccuracy: Double = -1
    /// 裝置指向的方位（度，0 = 正北）
    @Published private(set) var deviceHeading: Double = 0
    @Published private(set) var isUpdating = false

    private let manager = CLLocationManager()
    private var currentPowerMode: PowerMode = .precise

    enum PowerMode {
        /// 最高精度，適合慢速或剛起步
        case precise
        /// 一般跑步，略降取樣密度
        case balanced
        /// 低電量模式，明顯降頻
        case saver
    }
    /// 供錄製器訂閱的座標串流
    let locationSubject = PassthroughSubject<CLLocation, Never>()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysPermission() {
        manager.requestAlwaysAuthorization()
    }

    func startUpdating(background: Bool) {
        guard isAuthorized else {
            requestPermission()
            return
        }
        if background && authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        isUpdating = true
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        isUpdating = false
    }

    /// 依速度與低電量狀態調整取樣密度，長距離記錄可省下可觀電力
    func applyPowerProfile(speed: Double) {
        guard AppSettings.shared.batterySaver else {
            setPowerMode(.precise)
            return
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            setPowerMode(.saver)
        } else if speed > 2.2 {
            setPowerMode(.balanced)
        } else {
            setPowerMode(.precise)
        }
    }

    private func setPowerMode(_ mode: PowerMode) {
        guard mode != currentPowerMode else { return }
        currentPowerMode = mode
        switch mode {
        case .precise:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
        case .balanced:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 4
        case .saver:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 12
        }
    }

    var powerModeText: String {
        switch currentPowerMode {
        case .precise: return "最高精度"
        case .balanced: return "省電平衡"
        case .saver: return "低電量省電"
        }
    }

    /// 只取一次目前位置（用於地圖初始鏡頭）
    func requestOneShot() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let received = locations
        DispatchQueue.main.async {
            for location in received {
                guard location.horizontalAccuracy > 0 else { continue }
                self.latestLocation = location
                self.horizontalAccuracy = location.horizontalAccuracy
                self.locationSubject.send(location)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        DispatchQueue.main.async {
            self.deviceHeading = value
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失敗不中斷 App，其他模組照常運作。
    }
}
