import Foundation
import CoreLocation
import Combine

/// 定位權限與座標來源。定位被拒不會影響模組 B 的任何功能。
@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var horizontalAccuracy: Double = -1
    @Published private(set) var isUpdating = false

    private let manager = CLLocationManager()
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

    /// 只取一次目前位置（用於地圖初始鏡頭）
    func requestOneShot() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let received = locations
        Task { @MainActor in
            for location in received {
                guard location.horizontalAccuracy > 0 else { continue }
                self.latestLocation = location
                self.horizontalAccuracy = location.horizontalAccuracy
                self.locationSubject.send(location)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失敗不中斷 App，其他模組照常運作。
    }
}
