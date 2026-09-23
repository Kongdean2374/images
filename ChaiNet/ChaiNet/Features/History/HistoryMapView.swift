import SwiftUI
import MapKit
import ChaiNetCore

/// Results with an (opt-in, local-only) location.
struct HistoryMapView: View {
    let results: [TestResult]
    @Environment(SettingsStore.self) private var settings

    private var located: [TestResult] { results.filter { $0.location != nil } }

    var body: some View {
        if located.isEmpty {
            EmptyStateView(symbol: "map", title: "沒有位置資料",
                           message: settings.settings.storeLocation ? "開啟後的新測試會出現在地圖上。" : "位置儲存預設關閉，可在「設定 › 隱私」開啟；資料只存在本機。")
            Spacer()
        } else {
            Map {
                ForEach(located) { r in
                    if let loc = r.location {
                        Annotation(r.metrics.downloadMbps.map { Format.speed($0, settings: settings.settings) } ?? r.kind.displayName,
                                   coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)) {
                            Circle().fill(Theme.scoreColor(r.scores.overall)).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }
}
