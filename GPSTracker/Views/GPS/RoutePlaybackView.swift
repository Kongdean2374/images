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
    @State private var showExport = false

    /// 全部預先算好，播放時完全不重算，這是流暢的關鍵
    @State private var points: [RoutePoint] = []
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var speeds: [Double] = []
    @State private var allSegments: [RouteSegment] = []
    @State private var fastestRange: ClosedRange<Int>?

    /// 動畫時鐘
    @State private var lastTick: Date?
    @State private var lastCameraUpdate: Date = .distantPast

    /// 以浮點數表示的進度位置，頭部座標會在兩個點之間內插，不會一格一格跳
    private var exactPosition: Double {
        guard coordinates.count > 1 else { return 0 }
        return progress * Double(coordinates.count - 1)
    }

    /// 目前播放到的索引（整數部分）
    private var currentIndex: Int {
        guard coordinates.count > 1 else { return 0 }
        return min(coordinates.count - 1, max(0, Int(exactPosition)))
    }

    /// 內插後的頭部座標
    private var headCoordinate: CLLocationCoordinate2D? {
        guard coordinates.count > 1 else { return coordinates.first }
        let index = currentIndex
        guard index < coordinates.count - 1 else { return coordinates.last }
        let t = exactPosition - Double(index)
        let a = coordinates[index]
        let b = coordinates[index + 1]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// 已走過的路徑：只挑出整段落在進度之前的，不重新計算顏色
    private var visibleSegments: [RouteSegment] {
        let index = currentIndex
        return allSegments.filter { $0.startIndex <= index }
    }

    /// 銜接到頭部的那一小段，讓線條跟著頭一起長出來
    private var leadingCoordinates: [CLLocationCoordinate2D] {
        guard let head = headCoordinate, currentIndex < coordinates.count else { return [] }
        let anchor = max(0, currentIndex)
        return [coordinates[anchor], head]
    }

    private var playbackDuration: Double {
        max(8.0, Double(coordinates.count) / 30.0)
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
        .background {
            // 以畫面更新頻率驅動（60 / 120 Hz），不是固定 30 Hz 的 Timer
            TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { context in
                Color.clear
                    .onChange(of: context.date) { _, now in
                        advance(to: now)
                    }
            }
            .allowsHitTesting(false)
        }
        .onAppear { prepare() }
        .onChange(of: isPlaying) { _, playing in
            if playing { lastTick = nil }
        }
        .sheet(isPresented: $showExport) {
            RouteVideoExportView(session: session)
        }
    }

    /// 進場時一次算完所有繁重的東西
    private func prepare() {
        let sorted = session.sortedPoints
        points = sorted
        coordinates = sorted.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        speeds = sorted.map { $0.speed }
        allSegments = RouteRenderer.segments(coordinates: coordinates, speeds: speeds)

        let splits = StatsEngine.gpsSplits(points: sorted, splitDistance: 1000)
        fastestRange = splits.filter { $0.pace != nil && !$0.isPartial }
            .min { ($0.pace ?? .infinity) < ($1.pace ?? .infinity) }?
            .pointRange

        lastTick = nil
        updateCamera(force: true)
    }

    /// 依實際經過的時間推進，掉幀也不會變慢
    private func advance(to now: Date) {
        guard isPlaying, coordinates.count > 1 else { return }
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let delta = now.timeIntervalSince(last)
        guard delta > 0, delta < 0.5 else { return }

        progress = min(1, progress + (delta / playbackDuration) * rate)
        if progress >= 1 { isPlaying = false }
        updateCamera()
    }

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: .all) {
            // 已走過的路徑（依配速著色）
            ForEach(visibleSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            // 頭部那一小段，跟著內插座標一起長
            if leadingCoordinates.count == 2 {
                MapPolyline(coordinates: leadingCoordinates)
                    .stroke(Theme.accentWarm, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
            // 尚未走到的路徑（淡色預覽）
            if currentIndex < coordinates.count - 1 {
                MapPolyline(coordinates: Array(coordinates[currentIndex...]))
                    .stroke(Color.white.opacity(0.18),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [6, 8]))
            }
            if let head = headCoordinate {
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
            HStack(spacing: 10) {
                Button {
                    isPlaying = false
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel("匯出回放動畫")

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
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isInFastestSection)
    }

    private var controlPanel: some View {
        VStack(spacing: 14) {
            HStack {
                MetricTile(title: "已回放距離",
                           value: Fmt.distanceValue(points.isEmpty ? 0 : points[min(currentIndex, points.count - 1)].distanceFromStart,
                                                    unit: settings.unit),
                           unit: Fmt.distanceUnitLabel(settings.unit),
                           tint: Theme.accent, size: 26)
                MetricTile(title: "當下配速",
                           value: Fmt.pace(points.isEmpty ? nil : points[min(currentIndex, points.count - 1)].pace, unit: settings.unit),
                           tint: Theme.mint, size: 26)
                MetricTile(title: "海拔",
                           value: Fmt.decimal(points.isEmpty ? 0 : points[min(currentIndex, points.count - 1)].altitude, digits: 0),
                           unit: "m", tint: Theme.amber, size: 26)
            }

            Slider(value: $progress, in: 0...1)
                .tint(Theme.accent)
                .onChange(of: progress) { _, _ in updateCamera(force: true) }

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

    /// 鏡頭每 0.35 秒更新一次，動畫長度剛好接上，看起來是連續移動而不是一直重啟
    private func updateCamera(force: Bool = false) {
        guard let head = headCoordinate else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastCameraUpdate) < 0.35 { return }
        lastCameraUpdate = now

        let heading: Double
        if currentIndex > 3 {
            heading = GeoMath.bearing(from: coordinates[currentIndex - 3], to: head)
        } else {
            heading = 0
        }
        withAnimation(.linear(duration: force ? 0 : 0.36)) {
            camera = .camera(MapCamera(centerCoordinate: head,
                                       distance: isInFastestSection ? 380 : 900,
                                       heading: heading,
                                       pitch: isInFastestSection ? 70 : settings.mapPitch))
        }
    }
}
