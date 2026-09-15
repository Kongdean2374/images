import SwiftUI
import MapKit
import CoreLocation

/// A6 軌跡回放動畫：逐幀重播路徑延伸，最快配速段自動特寫放大。
struct RoutePlaybackView: View {
    let session: WorkoutSession

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var progress: Double = 0
    @State private var isPlaying = true
    @State private var rate: Double = 1
    @State private var camera: MapCameraPosition = .automatic
    @State private var timer: Timer?

    private var points: [RoutePoint] { session.sortedPoints }
    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    private var speeds: [Double] { points.map { $0.speed } }

    /// 目前播放到的索引
    private var currentIndex: Int {
        guard coordinates.count > 1 else { return 0 }
        return min(coordinates.count - 1, max(1, Int(progress * Double(coordinates.count - 1))))
    }

    private var visibleCoordinates: [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        return Array(coordinates[0...currentIndex])
    }

    /// 最快配速段（用於特寫）
    private var fastestRange: ClosedRange<Int>? {
        let splits = StatsEngine.gpsSplits(points: points, splitDistance: 1000)
        guard let best = splits.filter({ $0.pace != nil && !$0.isPartial })
            .min(by: { ($0.pace ?? .infinity) < ($1.pace ?? .infinity) }) else { return nil }
        return best.pointRange
    }

    private var isInFastestSection: Bool {
        guard let range = fastestRange else { return false }
        return range.contains(currentIndex)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer.ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                controlPanel
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: .all) {
            // 已走過的路徑（依配速著色）
            ForEach(RouteRenderer.segments(coordinates: visibleCoordinates,
                                           speeds: Array(speeds.prefix(visibleCoordinates.count)))) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            // 尚未走到的路徑（淡色預覽）
            if currentIndex < coordinates.count - 1 {
                MapPolyline(coordinates: Array(coordinates[currentIndex...]))
                    .stroke(Color.white.opacity(0.18),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [6, 8]))
            }
            if let head = visibleCoordinates.last {
                Annotation("", coordinate: head) {
                    TimelineView(.animation) { context in
                        let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
                        ZStack {
                            Circle()
                                .fill(Theme.accentWarm.opacity(0.25 + 0.2 * pulse))
                                .frame(width: 34 + 10 * pulse, height: 34 + 10 * pulse)
                            Circle()
                                .fill(Theme.accentWarm)
                                .frame(width: 15, height: 15)
                                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            Spacer()
            if isInFastestSection {
                Label("最快配速段", systemImage: "flame.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accentWarm)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            Menu {
                ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                    Button("\(Int(value))×") { rate = value }
                }
            } label: {
                Text("\(Int(rate))×")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(.ultraThinMaterial))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isInFastestSection)
    }

    private var controlPanel: some View {
        VStack(spacing: 14) {
            HStack {
                MetricTile(title: "已回放距離",
                           value: Fmt.distanceValue(points.isEmpty ? 0 : points[currentIndex].distanceFromStart,
                                                    unit: settings.unit),
                           unit: Fmt.distanceUnitLabel(settings.unit),
                           tint: Theme.accent, size: 26)
                MetricTile(title: "當下配速",
                           value: Fmt.pace(points.isEmpty ? nil : points[currentIndex].pace, unit: settings.unit),
                           tint: Theme.mint, size: 26)
                MetricTile(title: "海拔",
                           value: Fmt.decimal(points.isEmpty ? 0 : points[currentIndex].altitude, digits: 0),
                           unit: "m", tint: Theme.amber, size: 26)
            }

            Slider(value: $progress, in: 0...1)
                .tint(Theme.accent)
                .onChange(of: progress) { _, _ in updateCamera() }

            HStack(spacing: 30) {
                Button {
                    progress = 0
                    isPlaying = true
                } label: {
                    Image(systemName: "gobackward")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                Button {
                    isPlaying.toggle()
                    CueService.shared.impact(.soft)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.accent)
                }
                Button {
                    progress = 1
                    isPlaying = false
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                guard self.isPlaying else { return }
                let total = max(8.0, Double(self.coordinates.count) / 30.0)   // 基準播放長度（秒）
                self.progress = min(1, self.progress + (1.0 / (total * 30.0)) * self.rate)
                if self.progress >= 1 { self.isPlaying = false }
                self.updateCamera()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func updateCamera() {
        guard let head = visibleCoordinates.last else { return }
        let heading: Double
        if currentIndex > 2 {
            heading = GeoMath.bearing(from: coordinates[currentIndex - 2], to: head)
        } else {
            heading = 0
        }
        withAnimation(.easeOut(duration: 0.4)) {
            camera = .camera(MapCamera(centerCoordinate: head,
                                       distance: isInFastestSection ? 380 : 900,
                                       heading: heading,
                                       pitch: isInFastestSection ? 70 : settings.mapPitch))
        }
    }
}
