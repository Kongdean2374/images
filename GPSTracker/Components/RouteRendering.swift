import SwiftUI
import MapKit
import CoreLocation

/// 依配速著色的軌跡片段
struct RouteSegment: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
}

enum RouteRenderer {

    /// 將座標 + 速度切成小段，快段偏紅、慢段偏藍。
    static func segments(coordinates: [CLLocationCoordinate2D],
                         speeds: [Double],
                         chunkSize: Int = 6) -> [RouteSegment] {
        guard coordinates.count > 1 else { return [] }
        let valid = speeds.filter { $0 > 0.3 }.sorted()
        let low = valid.isEmpty ? 0 : valid[Int(Double(valid.count) * 0.1)]
        let high = valid.isEmpty ? 1 : valid[min(valid.count - 1, Int(Double(valid.count) * 0.9))]
        let span = max(0.35, high - low)

        var result: [RouteSegment] = []
        var index = 0
        while index < coordinates.count - 1 {
            let end = min(index + chunkSize, coordinates.count - 1)
            let slice = Array(coordinates[index...end])
            let speedSlice = speeds.isEmpty ? [] : Array(speeds[index...min(end, speeds.count - 1)])
            let avg = speedSlice.isEmpty ? low : speedSlice.reduce(0, +) / Double(speedSlice.count)
            let fraction = (avg - low) / span
            result.append(RouteSegment(coordinates: slice, color: Theme.paceColor(fraction: fraction)))
            index = end
        }
        return result
    }

    static func region(for coordinates: [CLLocationCoordinate2D], padding: Double = 1.4) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        var minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.002, (maxLat - minLat) * padding),
                                    longitudeDelta: max(0.002, (maxLon - minLon) * padding))
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// 可重複使用的軌跡地圖
struct RouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    let speeds: [Double]
    var highlightRange: ClosedRange<Int>?
    var showsMarkers: Bool = true
    var interactive: Bool = true
    var position: Binding<MapCameraPosition>?

    @State private var internalPosition: MapCameraPosition = .automatic

    private var segments: [RouteSegment] {
        RouteRenderer.segments(coordinates: coordinates, speeds: speeds)
    }

    private var highlightCoordinates: [CLLocationCoordinate2D] {
        guard let range = highlightRange,
              range.lowerBound >= 0,
              range.upperBound < coordinates.count else { return [] }
        return Array(coordinates[range])
    }

    var body: some View {
        Map(position: position ?? $internalPosition, interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if !highlightCoordinates.isEmpty {
                MapPolyline(coordinates: highlightCoordinates)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
            if showsMarkers, let first = coordinates.first {
                Annotation("起", coordinate: first) {
                    Circle()
                        .fill(Theme.mint)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if showsMarkers, let last = coordinates.last, coordinates.count > 1 {
                Annotation("終", coordinate: last) {
                    Circle()
                        .fill(Theme.accentWarm)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .onAppear {
            if position == nil, let region = RouteRenderer.region(for: coordinates) {
                internalPosition = .region(region)
            }
        }
    }
}
