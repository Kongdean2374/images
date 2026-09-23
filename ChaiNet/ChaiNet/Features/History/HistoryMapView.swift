import SwiftUI
import MapKit
import ChaiNetCore

/// Results with an (opt-in, local-only) location.
struct HistoryMapView: View {
    let results: [TestResult]
    @Environment(SettingsStore.self) private var settings

    private struct MapPoint: Identifiable {
        let result: TestResult
        let coordinate: CLLocationCoordinate2D
        var id: UUID { result.id }
    }

    private var located: [MapPoint] {
        results.compactMap { r in
            r.location.map { MapPoint(result: r, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
    }

    var body: some View {
        if located.isEmpty {
            EmptyStateView(symbol: "map", title: "沒有位置資料",
                           message: settings.settings.storeLocation ? "開啟後的新測試會出現在地圖上。" : "位置儲存預設關閉，可在「設定 › 隱私」開啟；資料只存在本機。")
            Spacer()
        } else {
            Map {
                ForEach(located) { point in
                    Annotation(label(point.result), coordinate: point.coordinate) {
                        Circle().fill(Theme.scoreColor(point.result.scores.overall)).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }

    private func label(_ r: TestResult) -> String {
        r.metrics.downloadMbps.map { Format.speed($0, settings: settings.settings) } ?? r.kind.displayName
    }
}
