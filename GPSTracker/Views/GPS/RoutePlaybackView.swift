import SwiftUI
import MapKit
import CoreLocation

/// 鏡頭模式：同一段軌跡可以用不同視角重播
enum PlaybackCamera: String, CaseIterable, Identifiable {
    /// 第一人稱跟隨，鏡頭壓低跟著轉向
    case follow3D
    /// 正上方俯視，頭部固定在畫面正中央
    case topDown
    /// 鏡頭不動，一次看完整條路線
    case overview
    /// 緩慢環繞，適合錄影分享
    case cinematic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .follow3D: return "跟隨 3D"
        case .topDown: return "俯視"
        case .overview: return "全覽"
        case .cinematic: return "環繞"
        }
    }

    var icon: String {
        switch self {
        case .follow3D: return "view.3d"
        case .topDown: return "map"
        case .overview: return "arrow.up.left.and.arrow.down.right"
        case .cinematic: return "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    var detail: String {
        switch self {
        case .follow3D: return "鏡頭壓低跟著你轉向，最有臨場感"
        case .topDown: return "正上方俯視，頭部永遠在畫面正中央"
        case .overview: return "鏡頭不動，一眼看完整條路線"
        case .cinematic: return "鏡頭緩慢環繞，錄影分享用"
        }
    }

    var followsHead: Bool { self != .overview }
}

/// A6 軌跡回放動畫：逐幀重播路徑延伸，可切換鏡頭與上色方式。
struct RoutePlaybackView: View {
    let session: WorkoutSession

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var progress: Double = 0
    @State private var isPlaying = true
    @State private var rate: Double = 1
    @State private var camera: MapCameraPosition = .automatic
    @State private var showExport = false
    @State private var showOptions = false

    @State private var cameraMode: PlaybackCamera = .follow3D
    @State private var colorMode: RouteColorMode = .pace
    @State private var showLegend = true

    /// 全部預先算好，播放時完全不重算，這是流暢的關鍵
    @State private var points: [RoutePoint] = []
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var allSegments: [RouteSegment] = []
    @State private var scale: RouteColorScale = .placeholder
    @State private var fastestRange: ClosedRange<Int>?
    @State private var ready = false
    /// 空白段（定位失效那幾段）的起始索引
    @State private var gapIndices: Set<Int> = []
    /// 整段的時間長度，回放改以時間推進，空白段才會依時間等速通過
    @State private var timeSpan: TimeInterval = 0

    /// 動畫時鐘
    @State private var lastTick: Date?
    @State private var orbitAngle: Double = 0

    // MARK: 位置計算

    /// 回放目前對應的「實際時刻」。以時間而不是索引推進，
    /// 所以沒有軌跡的空白段會依實際經過的時間等速通過，
    /// 而不是一瞬間跳到恢復定位的那一點。
    private var currentTime: Date {
        guard let first = points.first?.timestamp else { return Date() }
        return first.addingTimeInterval(progress * timeSpan)
    }

    /// 以時間換算出的浮點位置
    private var exactPosition: Double {
        guard points.count > 1 else { return 0 }
        let target = currentTime
        // 二分搜尋找出目標時間落在哪兩個點之間
        var low = 0
        var high = points.count - 1
        while low < high - 1 {
            let mid = (low + high) / 2
            if points[mid].timestamp <= target { low = mid } else { high = mid }
        }
        let a = points[low].timestamp
        let b = points[high].timestamp
        let span = b.timeIntervalSince(a)
        guard span > 0 else { return Double(low) }
        let fraction = min(1, max(0, target.timeIntervalSince(a) / span))
        return Double(low) + fraction
    }

    private var currentIndex: Int {
        guard coordinates.count > 1 else { return 0 }
        return min(coordinates.count - 1, max(0, Int(exactPosition)))
    }

    /// 現在正通過空白段嗎
    private var isCrossingGap: Bool {
        gapIndices.contains(currentIndex)
    }

    /// 內插後的頭部座標，兩點之間是連續移動而不是一格一格跳
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

    /// 已經走過的路徑。最後一段會裁切到頭部，線條才會剛好停在光點上。
    private var visibleSegments: [RouteSegment] {
        guard !allSegments.isEmpty, coordinates.count > 1 else { return [] }
        let index = currentIndex
        var result: [RouteSegment] = []
        result.reserveCapacity(min(allSegments.count, index + 2))

        for segment in allSegments {
            if segment.endIndex <= index {
                result.append(segment)
                continue
            }
            if segment.startIndex <= index {
                var clipped = Array(coordinates[segment.startIndex...index])
                if let head = headCoordinate { clipped.append(head) }
                if clipped.count > 1 {
                    result.append(RouteSegment(startIndex: segment.startIndex,
                                               endIndex: index,
                                               coordinates: clipped,
                                               value: segment.value,
                                               color: segment.color))
                }
            }
            break
        }
        return result
    }

    private var playbackDuration: Double {
        max(8.0, Double(coordinates.count) / 30.0)
    }

    /// 空白段的連線（虛線），從斷點直接連到恢復點
    private var gapLines: [[CLLocationCoordinate2D]] {
        gapIndices.sorted().compactMap { index in
            guard index + 1 < coordinates.count else { return nil }
            return [coordinates[index], coordinates[index + 1]]
        }
    }

    /// 已經走過的空白段連線
    private var visibleGapLines: [[CLLocationCoordinate2D]] {
        let position = exactPosition
        return gapIndices.sorted().compactMap { index in
            guard index + 1 < coordinates.count, Double(index) <= position else { return nil }
            let head = Double(index + 1) <= position
                ? coordinates[index + 1]
                : (headCoordinate ?? coordinates[index])
            return [coordinates[index], head]
        }
    }

    private var isInFastestSection: Bool {
        guard let range = fastestRange else { return false }
        return range.contains(currentIndex)
    }

    /// 目前這一點的速度（公尺/秒），用來決定鏡頭要拉多遠
    private var currentSpeed: Double {
        guard !points.isEmpty else { return 0 }
        return max(0, points[min(currentIndex, points.count - 1)].speed)
    }

    // MARK: 畫面

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if showLegend && colorMode != .solid { legendBar }
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
        .onChange(of: colorMode) { _, _ in rebuildColors() }
        .onChange(of: cameraMode) { _, _ in updateCamera(force: true) }
        .sheet(isPresented: $showExport) {
            RouteVideoExportView(session: session)
        }
        .sheet(isPresented: $showOptions) {
            optionsSheet
        }
    }

    // MARK: 準備資料

    private func prepare() {
        let sorted = session.sortedPoints
        guard sorted.count > 1 else { return }

        var working = sorted
        // 點太多先抽稀，視覺上看不出來但畫起來快很多
        if working.count > 4000 {
            let coords = working.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let keep = RouteRenderer.simplify(coords, tolerance: 2.5)
            if keep.count > 500 { working = keep.map { working[$0] } }
        }

        let coords = working.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let splits = StatsEngine.gpsSplits(points: sorted, splitDistance: 1000)
        let best = splits.filter { $0.pace != nil && !$0.isPartial }
            .min { ($0.pace ?? .infinity) < ($1.pace ?? .infinity) }?
            .pointRange

        points = working
        coordinates = coords
        fastestRange = best
        gapIndices = RouteRenderer.gapIndices(timestamps: working.map { $0.timestamp })
        if let first = working.first?.timestamp, let last = working.last?.timestamp {
            timeSpan = max(1, last.timeIntervalSince(first))
        }
        applyColors(points: working, coordinates: coords, mode: colorMode)
        ready = true
        lastTick = nil

        // 等 @State 寫入生效後再設鏡頭，否則讀到的還是空陣列
        DispatchQueue.main.async { updateCamera(force: true) }
    }

    /// 依目前的上色模式重建尺規與分段
    private func rebuildColors() {
        applyColors(points: points, coordinates: coordinates, mode: colorMode)
    }

    private func applyColors(points source: [RoutePoint],
                             coordinates coords: [CLLocationCoordinate2D],
                             mode: RouteColorMode) {
        guard !coords.isEmpty, !source.isEmpty else { return }
        let numbers: [Double]
        switch mode {
        case .elevation: numbers = source.map { $0.altitude }
        case .solid: numbers = source.map { _ in 0 }
        default: numbers = source.map { max(0, $0.speed) }
        }
        let built = RouteColorScale.make(mode: mode, values: numbers)
        scale = built
        let gaps = RouteRenderer.gapIndices(timestamps: source.map { $0.timestamp })
        allSegments = RouteRenderer.segments(coordinates: coords,
                                             values: numbers,
                                             scale: built,
                                             gapAfterIndex: gaps)
    }

    /// 依實際經過的時間推進，掉幀也不會變慢
    private func advance(to now: Date) {
        guard isPlaying, coordinates.count > 1 else { return }
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let delta = now.timeIntervalSince(last)
        guard delta > 0, delta < 0.5 else { return }

        progress = min(1, progress + (delta / playbackDuration) * rate)
        if cameraMode == .cinematic { orbitAngle += delta * 12 }
        if progress >= 1 { isPlaying = false }
        updateCamera()
    }

    // MARK: 地圖

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: cameraMode == .overview ? .all : [.zoom]) {
            // 還沒走到的路線：淡淡的預覽
            if currentIndex < coordinates.count - 1 {
                MapPolyline(coordinates: Array(coordinates[currentIndex...]))
                    .stroke(Color.white.opacity(0.22),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [7, 9]))
            }

            // 空白段：用虛線標示「這段沒有軌跡」
            ForEach(Array(visibleGapLines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Color.white.opacity(0.55),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2, 10]))
            }

            // 已走過的路線：先畫一層較寬的半透明當作發光底層
            ForEach(visibleSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color.opacity(0.32),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
            }
            ForEach(visibleSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }

            if let first = coordinates.first {
                Annotation("", coordinate: first) {
                    Circle()
                        .fill(Theme.mint)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                }
            }

            if let head = headCoordinate {
                Annotation("", coordinate: head) {
                    TimelineView(.animation) { context in
                        let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
                        ZStack {
                            Circle()
                                .fill(Theme.accentWarm.opacity(0.22 + 0.18 * pulse))
                                .frame(width: 36 + 12 * pulse, height: 36 + 12 * pulse)
                            Circle()
                                .fill(Theme.accentWarm)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        }
                    }
                }
            }
        }
        .mapStyle(mapStyle)
    }

    private var mapStyle: MapStyle {
        switch settings.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }

    /// 鏡頭每幀直接設定、不加動畫，頭部才會穩穩停在畫面正中央
    private func updateCamera(force: Bool = false) {
        guard ready || force else { return }

        if cameraMode == .overview {
            if let region = RouteRenderer.region(for: coordinates, padding: 1.35) {
                withAnimation(.easeInOut(duration: force ? 0.45 : 0)) {
                    camera = .region(region)
                }
            }
            return
        }

        guard let head = headCoordinate else { return }

        // 速度越快鏡頭拉越遠，看得到前方；慢下來就拉近
        let base: Double = isInFastestSection ? 360 : 780
        let distance = min(2200, base + currentSpeed * 95)

        let heading: Double
        switch cameraMode {
        case .topDown:
            heading = 0
        case .cinematic:
            heading = orbitAngle.truncatingRemainder(dividingBy: 360)
        default:
            heading = currentIndex > 3
                ? GeoMath.bearing(from: coordinates[currentIndex - 3], to: head)
                : 0
        }

        let pitch: Double
        switch cameraMode {
        case .topDown: pitch = 0
        case .cinematic: pitch = 62
        default: pitch = isInFastestSection ? 68 : settings.mapPitch
        }

        let target = MapCamera(centerCoordinate: head,
                               distance: cameraMode == .topDown ? min(1600, distance * 0.9) : distance,
                               heading: heading,
                               pitch: pitch)

        if force {
            withAnimation(.easeInOut(duration: 0.45)) { camera = .camera(target) }
        } else {
            camera = .camera(target)
        }
    }

    // MARK: 上方列

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
            if isCrossingGap {
                Label("這段沒有定位訊號", systemImage: "location.slash.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .transition(.scale.combined(with: .opacity))
            } else if isInFastestSection {
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
                    showOptions = true
                    CueService.shared.impact(.soft)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel("回放設定")

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
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isInFastestSection)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isCrossingGap)
    }

    /// 顏色尺規圖例
    private var legendBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(0..<40, id: \.self) { step in
                    Rectangle()
                        .fill(Theme.routeGradient(fraction: Double(step) / 39))
                        .frame(height: 6)
                }
            }
            .clipShape(Capsule())

            HStack {
                ForEach(Array(scale.legend(unit: settings.unit).enumerated()), id: \.offset) { _, item in
                    Text(item.label)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                }
            }

            Text(legendCaption)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.horizontal, 26)
        .padding(.top, 8)
    }

    private var legendCaption: String {
        switch colorMode {
        case .elevation: return "海拔（公尺）"
        case .solid: return ""
        default: return settings.unit == .metric ? "速度（公里/小時）" : "速度（英里/小時）"
        }
    }

    // MARK: 設定表

    private var optionsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PlaybackCamera.allCases) { mode in
                        Button {
                            cameraMode = mode
                            CueService.shared.impact(.soft)
                        } label: {
                            optionRow(title: mode.displayName,
                                      detail: mode.detail,
                                      icon: mode.icon,
                                      selected: cameraMode == mode)
                        }
                    }
                } header: {
                    Text("鏡頭模式")
                } footer: {
                    Text("俯視模式的光點永遠在畫面正中央；跟隨 3D 因為鏡頭壓低，光點會略偏下方，這是透視造成的。")
                }

                Section {
                    ForEach(RouteColorMode.allCases) { mode in
                        Button {
                            colorMode = mode
                            CueService.shared.impact(.soft)
                        } label: {
                            optionRow(title: mode.displayName,
                                      detail: mode.detail,
                                      icon: mode.icon,
                                      selected: colorMode == mode)
                        }
                    }
                    Toggle("顯示顏色尺規", isOn: $showLegend)
                } header: {
                    Text("軌跡上色")
                } footer: {
                    Text("「絕對速度」的尺規是 0 到本次最高速，所以某一段突然衝很快時，整條線會重新分級，不會全部擠在紅色。")
                }

                Section("地圖樣式") {
                    Picker("地圖樣式", selection: $settings.mapStyleIndex) {
                        Text("標準").tag(0)
                        Text("混合").tag(1)
                        Text("衛星").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("回放設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showOptions = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func optionRow(title: String, detail: String, icon: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.mint)
            }
        }
    }

    // MARK: 下方控制

    private var controlPanel: some View {
        VStack(spacing: 14) {
            HStack {
                MetricTile(title: "已回放距離",
                           value: Fmt.distanceValue(points.isEmpty ? 0 : points[min(currentIndex, points.count - 1)].distanceFromStart,
                                                    unit: settings.unit),
                           unit: Fmt.distanceUnitLabel(settings.unit),
                           tint: Theme.accent, size: 26)
                MetricTile(title: colorMode == .elevation ? "海拔" : "當下配速",
                           value: colorMode == .elevation
                                ? Fmt.decimal(points.isEmpty ? 0 : points[min(currentIndex, points.count - 1)].altitude, digits: 0)
                                : Fmt.pace(points.isEmpty ? nil : points[min(currentIndex, points.count - 1)].pace, unit: settings.unit),
                           unit: colorMode == .elevation ? "m" : nil,
                           tint: Theme.mint, size: 26)
                MetricTile(title: "速度",
                           value: String(format: "%.1f", currentSpeed * 3.6),
                           unit: "km/h", tint: Theme.amber, size: 26)
            }

            Slider(value: $progress, in: 0...1)
                .tint(Theme.accent)
                .onChange(of: progress) { _, _ in updateCamera(force: true) }

            HStack(spacing: 26) {
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
                Menu {
                    ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                        Button("\(Int(value))×") { rate = value }
                    }
                } label: {
                    Text("\(Int(rate))×")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
