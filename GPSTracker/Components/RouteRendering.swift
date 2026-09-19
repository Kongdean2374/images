import SwiftUI
import MapKit
import CoreLocation

/// 軌跡上色的依據
enum RouteColorMode: String, CaseIterable, Identifiable, Codable {
    /// 相對配速：依這次紀錄自己的速度分佈自動分級（快慢的相對關係最清楚）
    case pace
    /// 絕對速度：固定以 0 到觀測到的最高速為尺規，最高速變快時整條線會重新分級
    case speed
    /// 海拔高低
    case elevation
    /// 單色，只看路線形狀
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pace: return "相對配速"
        case .speed: return "絕對速度"
        case .elevation: return "海拔"
        case .solid: return "單色"
        }
    }

    var icon: String {
        switch self {
        case .pace: return "speedometer"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .elevation: return "mountain.2.fill"
        case .solid: return "line.diagonal"
        }
    }

    var detail: String {
        switch self {
        case .pace: return "以這次紀錄的速度分佈自動分級，看得出哪裡相對快、哪裡相對慢"
        case .speed: return "以 0 到本次最高速為尺規，最高速一變快整條線就重新分級"
        case .elevation: return "低處藍、高處紅，適合看爬升路線"
        case .solid: return "不分顏色，只看路線本身"
        }
    }
}

/// 把數值換成顏色的尺規。最高速變大時重新建立，整條軌跡就會即時跟著重新分級。
struct RouteColorScale: Equatable {
    let mode: RouteColorMode
    let low: Double
    let high: Double

    static let placeholder = RouteColorScale(mode: .solid, low: 0, high: 1)

    /// 依實際資料建立尺規
    static func make(mode: RouteColorMode, values: [Double]) -> RouteColorScale {
        switch mode {
        case .solid:
            return RouteColorScale(mode: .solid, low: 0, high: 1)

        case .pace:
            // 用 5%–95% 百分位，避免一兩個 GPS 跳點把整個尺規拉壞
            let valid = values.filter { $0 > 0.3 }.sorted()
            guard valid.count > 4 else { return RouteColorScale(mode: .pace, low: 0, high: 1) }
            let low = valid[Int(Double(valid.count) * 0.05)]
            let high = valid[min(valid.count - 1, Int(Double(valid.count) * 0.95))]
            return RouteColorScale(mode: .pace, low: low, high: max(low + 0.35, high))

        case .speed:
            // 尺規永遠是 0 到「目前看到的最高速」，所以突然衝到 40 km/h 時
            // 整條線會自動重新分級，不會全部擠在紅色那一端
            let peak = values.filter { $0.isFinite }.max() ?? 1
            return RouteColorScale(mode: .speed, low: 0, high: max(1.0, peak))

        case .elevation:
            let valid = values.filter { $0.isFinite }
            let low = valid.min() ?? 0
            let high = valid.max() ?? (low + 1)
            return RouteColorScale(mode: .elevation, low: low, high: max(low + 1, high))
        }
    }

    func fraction(for value: Double) -> Double {
        guard high > low else { return 0.5 }
        return min(1, max(0, (value - low) / (high - low)))
    }

    func color(for value: Double) -> Color {
        guard mode != .solid else { return Theme.accent }
        return Theme.routeGradient(fraction: fraction(for: value))
    }

    /// 尺規要不要重建：最高值成長超過 12% 就重算，播放中才會「即時」跟著調整
    func needsRebuild(forNewPeak peak: Double) -> Bool {
        guard mode == .speed || mode == .pace else { return false }
        return peak > high * 1.12
    }

    /// 圖例：五格，從尺規低端到高端
    func legend(unit: DistanceUnit) -> [(label: String, color: Color)] {
        guard mode != .solid else { return [] }
        return (0..<5).map { step in
            let t = Double(step) / 4
            let value = low + (high - low) * t
            return (label(for: value, unit: unit), Theme.routeGradient(fraction: t))
        }
    }

    private func label(for value: Double, unit: DistanceUnit) -> String {
        switch mode {
        case .elevation:
            return String(format: "%.0fm", value)
        case .speed, .pace:
            let kmh = value * 3.6
            return String(format: "%.0f", unit == .metric ? kmh : kmh / 1.609344)
        case .solid:
            return ""
        }
    }
}

/// 依速度／海拔著色的軌跡片段
struct RouteSegment: Identifiable {
    /// 用起點索引當 id，重新計算時 SwiftUI 才不會把每一段都當成新的而整條重畫
    var id: Int { startIndex }
    let startIndex: Int
    let endIndex: Int
    let coordinates: [CLLocationCoordinate2D]
    /// 這一段的代表值（速度或海拔），顏色在繪製時才依當下尺規換算
    let value: Double
    /// 預先算好的顏色，尺規沒變時直接用
    let color: Color
}

enum RouteRenderer {

    /// 分段數量上限。點再多也只切這麼多段，長距離路線才不會卡。
    static let maxSegments = 420

    /// 將座標 + 數值切成小段。段數越多漸層越細緻，但太多會拖慢地圖，
    /// 所以依點數自動調整每段長度，維持在 maxSegments 以內。
    static func segments(coordinates: [CLLocationCoordinate2D],
                         values: [Double],
                         scale: RouteColorScale) -> [RouteSegment] {
        guard coordinates.count > 1 else { return [] }
        let chunkSize = max(1, Int(ceil(Double(coordinates.count) / Double(maxSegments))))

        var result: [RouteSegment] = []
        result.reserveCapacity(min(maxSegments + 2, coordinates.count))

        var index = 0
        while index < coordinates.count - 1 {
            let end = min(index + chunkSize, coordinates.count - 1)
            let slice = Array(coordinates[index...end])
            let valueSlice = values.isEmpty ? [] : Array(values[index...min(end, values.count - 1)])
            let average = valueSlice.isEmpty ? scale.low : valueSlice.reduce(0, +) / Double(valueSlice.count)
            result.append(RouteSegment(startIndex: index,
                                       endIndex: end,
                                       coordinates: slice,
                                       value: average,
                                       color: scale.color(for: average)))
            index = end
        }
        return result
    }

    /// 舊介面：只給速度時預設用相對配速尺規
    static func segments(coordinates: [CLLocationCoordinate2D],
                         speeds: [Double]) -> [RouteSegment] {
        let scale = RouteColorScale.make(mode: .pace, values: speeds)
        return segments(coordinates: coordinates, values: speeds, scale: scale)
    }

    /// Douglas–Peucker 簡化：長路線先抽稀再畫，視覺上看不出差別但快很多
    static func simplify(_ coordinates: [CLLocationCoordinate2D],
                         tolerance: Double) -> [Int] {
        guard coordinates.count > 2 else { return Array(coordinates.indices) }
        var keep = [Bool](repeating: false, count: coordinates.count)
        keep[0] = true
        keep[coordinates.count - 1] = true

        var stack: [(Int, Int)] = [(0, coordinates.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDistance = 0.0
            var maxIndex = first
            for i in (first + 1)..<last {
                let distance = perpendicularDistance(coordinates[i],
                                                     from: coordinates[first],
                                                     to: coordinates[last])
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = i
                }
            }
            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((first, maxIndex))
                stack.append((maxIndex, last))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    private static func perpendicularDistance(_ point: CLLocationCoordinate2D,
                                              from a: CLLocationCoordinate2D,
                                              to b: CLLocationCoordinate2D) -> Double {
        // 以公尺為單位的近似平面距離，短距離內誤差可忽略
        let scaleLon = cos(a.latitude * .pi / 180) * 111_320
        let scaleLat = 110_540.0
        let px = (point.longitude - a.longitude) * scaleLon
        let py = (point.latitude - a.latitude) * scaleLat
        let bx = (b.longitude - a.longitude) * scaleLon
        let by = (b.latitude - a.latitude) * scaleLat
        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return hypot(px, py) }
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        return hypot(px - bx * t, py - by * t)
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
