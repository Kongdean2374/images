import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

struct GPSTrackingView: View {
    let type: WorkoutType

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var recorder = GPSWorkoutRecorder()
    @StateObject private var location = LocationManager.shared

    @State private var camera: MapCameraPosition = .automatic
    @State private var followCamera = true
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false
    @State private var expandedMetrics = true

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
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if location.isAuthorized {
                location.startUpdating(background: false)
                location.requestOneShot()
            } else if !location.isDenied {
                location.requestPermission()
            }
        }
        .onDisappear {
            if recorder.state == .recording || recorder.state == .paused {
                recorder.stop()
            }
            location.stopUpdating()
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
        .alert("結束這次運動？", isPresented: $showStopConfirm) {
            Button("繼續記錄", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finish() }
        } message: {
            Text("已記錄 \(Fmt.distance(recorder.distance, unit: settings.unit))，時間 \(Fmt.duration(recorder.elapsed))")
        }
    }

    // MARK: 地圖

    private var mapLayer: some View {
        Map(position: $camera, interactionModes: .all) {
            UserAnnotation()
            ForEach(RouteRenderer.segments(coordinates: recorder.coordinates,
                                           speeds: recorder.samples.map { $0.speed })) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
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
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
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

            if expandedMetrics {
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
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
