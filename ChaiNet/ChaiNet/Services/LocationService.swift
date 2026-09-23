import Foundation
import CoreLocation
import ChaiNetCore

/// Optional, opt-in location for results. Stored only on the device; never sent to a server.
@MainActor
final class LocationService {
    private let manager = CLLocationManager()

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// One reasonably accurate fix, or nil after `timeout` / without permission.
    func currentLocation(timeout: Double = 4) async -> GeoPoint? {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return await withTaskGroup(of: GeoPoint?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = update.location, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 500 {
                            return GeoPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                                            horizontalAccuracy: loc.horizontalAccuracy)
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
