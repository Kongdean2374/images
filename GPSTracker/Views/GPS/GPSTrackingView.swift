import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

struct GPSTrackingView: View {
    let type: WorkoutType
    /// 多項運動時對應的運動種類（跑步／健行留空）
    var sport: SportKind? = nil
    /// 來源運動項目（有的話右上角會出現專屬設定）
    var discipline: Discipline? = nil
    /// 開啟該項目的獨立設定頁
    var onSettings: (() -> Void)? = nil
    /// 從中斷的自動存檔接續記錄
    var restoring: ActiveWorkoutSnapshot? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var recorder = GPSWorkoutRecorder()
    @StateObject private var location = LocationManager.shared

    @State private var camera: MapCameraPosition = .automatic
    @State private var followCamera = true
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false
    @State private var saveErrorMessage: String?
    @State private var expandedMetrics = true
    @State private var showPaceEditor = false
    @State private var showLapEditor = false
    @State private var showBackToStart = false
    @State private var bigTextMode = false
    @State private var showAccuracyHint = false


    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if location.isAuthorized {
                    metricsPanel
                } else {
                    permissionPanel
                }
            }

            if bigTextMode { bigTextOverlay }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            recorder.workoutType = type
            recorder.sport = sport
            bigTextMode = settings.preferBigText
            applyStoredOptions()
            if let restoring, recorder.state == .idle {
                recorder.restore(from: restoring)
            }
            if location.isAuthorized {
                location.startUpdating(background: settings.backgroundLocation)
                location.requestOneShot()
                location.requestFullAccuracy()
                showAccuracyHint = location.isReducedAccuracy
            } else if !location.isDenied {
                location.requestPermission()
            }
        }
        .onDisappear {
            // 以前這裡直接 stop()，畫面一消失整場運動就被丟掉。
            // 現在改成強制存檔，下次開啟 App 會問要不要接續或儲存。
            if recorder.state == .recording || recorder.state == .paused {
                recorder.autosave(force: true)
            }
            location.stopUpdating()
        }
        .onChange(of: scenePhase) { _, phase in
            // 進背景／被系統終止前的最後機會，一定要把進度寫下來
            if phase != .active {
                recorder.autosave(force: true)
            }
        }
        .onChange(of: recorder.samples.count) { _, _ in
            updateCamera()
        }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .sheet(isPresented: $showPaceEditor) {
            PaceEditorSheet(unit: settings.unit,
                            initialSecondsPerKM: settings.gpsTargetPace) { value in
                applyPace(value)
                if value > 0 { settings.addCustomPace(value) }
            }
        }
        .sheet(isPresented: $showLapEditor) {
            DistanceEditorSheet(title: "自訂分圈距離",
                                unit: settings.unit,
                                initialMeters: settings.gpsAutoLapDistance,
                                suggestions: [200, 400, 500, 1000, 1609.344, 2000, 5000]) { value in
                applyLap(value)
                if value > 0 { settings.addCustomLapDistance(value) }
            }
        }
        .saveErrorAlert($saveErrorMessage)
        .alert("結束這次運動？", isPresented: $showStopConfirm) {
            Button("繼續記錄", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finish() }
        } message: {
            Text("已記錄 \(Fmt.distance(recorder.distance, unit: settings.unit))，時間 \(Fmt.duration(recorder.elapsed))")
        }
    }

    /// 從設定頁帶入這個項目儲存的偏好
    private func applyStoredOptions() {
        recorder.targetPace = settings.gpsTargetPace > 0 ? settings.gpsTargetPace : nil
        recorder.autoLapDistance = settings.gpsAutoLapDistance
    }

    // MARK: 地圖

    /// 即時軌跡：尺規每次都依「目前為止看到的資料」重建，
    /// 所以中途忽然衝到很高的速度時，整條線會立刻重新分級，不會全部變紅。
    private var liveSegments: [RouteSegment] {
        let speeds = recorder.samples.map { max(0, $0.speed) }
        let values: [Double] = settings.routeColorMode == .elevation
            ? recorder.samples.map { $0.altitude }
            : speeds
        let scale = RouteColorScale.make(mode: settings.routeColorMode, values: values)
        return RouteRenderer.segments(coordinates: recorder.coordinates,
                                      values: values,
                                      scale: scale)
    }

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: .all) {
            UserAnnotation()
            // 發光底層
            ForEach(liveSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color.opacity(0.30),
                            style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
            }
            ForEach(liveSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            if let first = recorder.coordinates.first {
                Annotation("起點", coordinate: first) {
                    Circle()
                        .fill(Theme.mint)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(currentMapStyle)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    private var currentMapStyle: MapStyle {
        switch settings.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }

    private func updateCamera() {
        guard followCamera, let last = recorder.samples.last else { return }
        withAnimation(.easeInOut(duration: 0.85)) {
            camera = .camera(MapCamera(centerCoordinate: last.coordinate,
                                       distance: 620,
                                       heading: recorder.heading,
                                       pitch: settings.mapPitch))
        }
    }

    // MARK: 上方列

    private var topBar: some View {
        HStack {
            Button {
                if recorder.state == .idle {
                    dismiss()
                } else {
                    showStopConfirm = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(.ultraThinMaterial))
            }

            Spacer()

            if recorder.isAutoPaused {
                Label("自動暫停", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            HStack(spacing: 10) {
                if let onSettings {
                    Button {
                        CueService.shared.impact(.soft)
                        onSettings()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .accessibilityLabel("這個項目的設定")
                }
                if recorder.state != .idle {
                    Button {
                        withAnimation(.easeIn(duration: 0.22)) { bigTextMode = true }
                        CueService.shared.impact(.medium)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                }
                Button {
                    settings.mapStyleIndex = (settings.mapStyleIndex + 1) % 3
                    CueService.shared.impact(.soft)
                } label: {
                    Image(systemName: settings.mapStyleIndex == 0 ? "map" : (settings.mapStyleIndex == 1 ? "globe.americas" : "photo"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                Button {
                    followCamera.toggle()
                    if followCamera { updateCamera() }
                    CueService.shared.impact(.soft)
                } label: {
                    Image(systemName: followCamera ? "location.fill" : "location")
                        .font(.headline)
                        .foregroundStyle(followCamera ? Theme.accent : .white)
                        .padding(11)
                        .background(Circle().fill(.ultraThinMaterial))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: recorder.isAutoPaused)
    }

    // MARK: 數據面板

    private var metricsPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: accuracyIcon)
                    .foregroundStyle(accuracyColor)
                Text(accuracyText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedMetrics.toggle()
                    }
                } label: {
                    Image(systemName: expandedMetrics ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                MetricTile(title: "距離",
                           value: Fmt.distanceValue(recorder.distance, unit: settings.unit),
                           unit: Fmt.distanceUnitLabel(settings.unit),
                           systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                           tint: Theme.accent,
                           size: 40)
                MetricTile(title: "時間",
                           value: Fmt.duration(recorder.elapsed),
                           systemImage: "stopwatch",
                           tint: Theme.textPrimary,
                           size: 40)
            }

            if recorder.state == .idle {
                setupPanel
            }

            if recorder.state != .idle, recorder.targetPace != nil {
                pacerBar
            }

            if recorder.state != .idle, let toStart = recorder.distanceToStart, toStart > 30 {
                backToStartRow(distance: toStart)
            }

            if expandedMetrics, recorder.state != .idle {
                HStack {
                    MetricTile(title: "即時配速",
                               value: Fmt.pace(recorder.currentPace, unit: settings.unit),
                               unit: Fmt.paceUnitLabel(settings.unit),
                               systemImage: "speedometer",
                               tint: Theme.mint,
                               size: 26)
                    MetricTile(title: "平均配速",
                               value: Fmt.pace(recorder.averagePace, unit: settings.unit),
                               systemImage: "chart.line.flattrend.xyaxis",
                               tint: Theme.textPrimary,
                               size: 26)
                }
                HStack {
                    MetricTile(title: "累積爬升",
                               value: Fmt.decimal(recorder.elevationGain, digits: 0),
                               unit: "m",
                               systemImage: "arrow.up.right",
                               tint: Theme.amber,
                               size: 26)
                    MetricTile(title: "累積下降",
                               value: Fmt.decimal(recorder.elevationLoss, digits: 0),
                               unit: "m",
                               systemImage: "arrow.down.right",
                               tint: Theme.violet,
                               size: 26)
                }
                .transition(.opacity)
            }

            controls
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: expandedMetrics)
    }

    // MARK: 大字模式（跑步中看得清楚，也避免誤觸）

    private var bigTextOverlay: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 30) {
                Spacer()
                VStack(spacing: 2) {
                    Text(Fmt.distanceValue(recorder.distance, unit: settings.unit))
                        .font(.system(size: 92, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                    Text(Fmt.distanceUnitLabel(settings.unit))
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                VStack(spacing: 2) {
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.system(size: 62, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.mint)
                    Text("時間")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
                VStack(spacing: 2) {
                    Text(Fmt.pace(recorder.currentPace ?? recorder.averagePace, unit: settings.unit))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.accent)
                    Text("配速")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
                if recorder.isAutoPaused || recorder.state == .paused {
                    Label("已暫停", systemImage: "pause.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
                Spacer()

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                        Text("畫面已鎖定，口袋誤觸不會離開")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.4))

                    SlideToConfirm(title: "滑動以離開大字模式",
                                   icon: "chevron.right",
                                   tint: Theme.accent) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            bigTextMode = false
                        }
                    }
                    .padding(.horizontal, 26)
                }
                .padding(.bottom, 34)
            }
        }
        .transition(.opacity)
    }

    // MARK: 開始前設定

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            valueChipRow(title: "虛擬配速員",
                         values: settings.customPaces,
                         current: settings.gpsTargetPace,
                         label: { Fmt.pace($0, unit: settings.unit) }) { value in
                applyPace(value)
            } onCustom: {
                showPaceEditor = true
            }

            valueChipRow(title: "自動分圈",
                         values: settings.customLapDistances,
                         current: settings.gpsAutoLapDistance,
                         label: { Fmt.distance($0, unit: settings.unit) }) { value in
                applyLap(value)
            } onCustom: {
                showLapEditor = true
            }
        }
    }

    private func applyPace(_ value: Double) {
        settings.gpsTargetPace = value
        recorder.targetPace = value > 0 ? value : nil
    }

    private func applyLap(_ value: Double) {
        settings.gpsAutoLapDistance = value
        recorder.autoLapDistance = value
    }

    /// 快捷列：關閉 + 使用者自訂的清單 + 自訂按鈕
    private func valueChipRow(title: String,
                              values: [Double],
                              current: Double,
                              label: @escaping (Double) -> String,
                              onSelect: @escaping (Double) -> Void,
                              onCustom: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip(text: "關閉", selected: current == 0) { onSelect(0) }
                    ForEach(values, id: \.self) { value in
                        chip(text: label(value), selected: abs(current - value) < 0.5) {
                            onSelect(value)
                        }
                    }
                    if current > 0 && !values.contains(where: { abs($0 - current) < 0.5 }) {
                        chip(text: label(current), selected: true) {}
                    }
                    Button {
                        onCustom()
                        CueService.shared.impact(.soft)
                    } label: {
                        Label("自訂", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.violet.opacity(0.25)))
                            .foregroundStyle(Theme.violet)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            CueService.shared.impact(.soft)
        } label: {
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.3) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var pacerBar: some View {
        let lead = recorder.timeLead ?? 0
        let ahead = lead >= 0
        let magnitude = min(1, abs(lead) / 60)
        return VStack(spacing: 6) {
            HStack {
                Label(ahead ? "領先目標" : "落後目標",
                      systemImage: ahead ? "hare.fill" : "tortoise.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ahead ? Theme.mint : Theme.amber)
                Spacer()
                Text(String(format: "%@%d 秒・%@%.0f m",
                            ahead ? "+" : "-", Int(abs(lead)),
                            ahead ? "+" : "-", abs(recorder.paceLead ?? 0)))
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .center) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(ahead ? Theme.mint : Theme.amber)
                        .frame(width: max(4, geo.size.width / 2 * magnitude))
                        .offset(x: ahead ? geo.size.width / 4 * magnitude : -geo.size.width / 4 * magnitude)
                        .animation(.easeOut(duration: 0.4), value: magnitude)
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 2, height: 12)
                }
            }
            .frame(height: 12)
        }
    }

    // MARK: 返回起點

    private func backToStartRow(distance: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.accent)
                .rotationEffect(.degrees((recorder.bearingToStart ?? 0) - location.deviceHeading))
                .animation(.easeOut(duration: 0.3), value: location.deviceHeading)
            VStack(alignment: .leading, spacing: 1) {
                Text("回到起點")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text(Fmt.distance(distance, unit: settings.unit))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
            if !recorder.laps.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("已分圈")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(recorder.laps.count)　\(Fmt.pace(recorder.laps.last?.pace, unit: settings.unit))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.mint)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var controls: some View {
        HStack(spacing: 26) {
            switch recorder.state {
            case .idle:
                Button {
                    recorder.routeKey = ""
                    recorder.start(type: type)
                } label: {
                    Label("開始記錄", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .recording:
                CircleControlButton(systemImage: "pause.fill", title: "暫停", tint: Theme.amber) {
                    recorder.pause()
                }
                CircleControlButton(systemImage: "stop.fill", title: "結束", tint: Theme.accentWarm) {
                    showStopConfirm = true
                }
            case .paused:
                CircleControlButton(systemImage: "play.fill", title: "繼續", tint: Theme.mint) {
                    recorder.resume()
                }
                CircleControlButton(systemImage: "stop.fill", title: "結束", tint: Theme.accentWarm) {
                    showStopConfirm = true
                }
            case .finished:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var permissionPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("需要定位權限", systemImage: "location.slash")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("GPS 模式需要定位才能記錄軌跡。你仍然可以使用營區計圈、室內間歇、原地運動與手動輸入，完全不需要定位。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    Button("開啟權限") {
                        if location.isDenied {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } else {
                            location.requestPermission()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("返回") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    // MARK: 精度

    private var accuracyIcon: String {
        let acc = location.horizontalAccuracy
        if acc < 0 { return "antenna.radiowaves.left.and.right.slash" }
        if acc < 10 { return "antenna.radiowaves.left.and.right" }
        return "wave.3.right"
    }

    private var accuracyColor: Color {
        let acc = location.horizontalAccuracy
        if acc < 0 { return Theme.accentWarm }
        if acc < 10 { return Theme.mint }
        if acc < 25 { return Theme.amber }
        return Theme.accentWarm
    }

    private var accuracyText: String {
        let acc = location.horizontalAccuracy
        if acc < 0 { return "等待 GPS 訊號" }
        return String(format: "GPS 精度 ±%.0f 公尺", acc)
    }

    // MARK: 結束

    private func finish() {
        recorder.stop()
        let session = recorder.buildSession(weatherNote: nil, temperature: nil)
        // 統一走 SessionSaver：儲存失敗會回報，也不會提早刪掉自動存檔
        if case .failed(let message) = SessionSaver.save(session, context: context) {
            saveErrorMessage = message
            return
        }
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
