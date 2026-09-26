import SwiftUI
import SwiftData

/// B1 + B2：營區計圈（完全不需定位）
struct LapCounterView: View {
    var mode: WorkoutType = .lapCounter
    /// 開啟該項目的獨立設定頁（由 DisciplineHostView 提供）
    var onSettings: (() -> Void)? = nil


    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var engine = LapWorkoutEngine()
    @StateObject private var pedometer = PedometerManager()

    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false
    @State private var saveErrorMessage: String?
    @State private var showDistanceSheet = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar

                if engine.state == .idle {
                    setupPanel
                } else {
                    runningPanel
                }

                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .saveErrorAlert($saveErrorMessage)
        .onDisappear {
            pedometer.stop()
        }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .alert(mode == .shuttleRun ? "結束折返跑？" : "結束計圈？", isPresented: $showStopConfirm) {
            Button("繼續", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finish() }
        } message: {
            Text("已完成 \(engine.laps.count) \(mode == .shuttleRun ? "趟" : "圈")，共 \(Fmt.distance(engine.totalDistance, unit: settings.unit))")
        }
        .sheet(isPresented: $showDistanceSheet) { distanceSheet }
    }

    private var topBar: some View {
        HStack {
            Button {
                if engine.state == .idle { dismiss() } else { showStopConfirm = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            Spacer()
            Text(mode.displayName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let onSettings {
                Button {
                    CueService.shared.impact(.soft)
                    onSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .accessibilityLabel("這個項目的設定")
            }
            Button {
                showDistanceSheet = true
            } label: {
                Image(systemName: "ruler")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.top, 6)
    }

    private var setupPanel: some View {
        VStack(spacing: 16) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("不需要定位權限", systemImage: "location.slash.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                    Text(mode == .shuttleRun
                         ? "設定單趟距離後開始計時，每跑完一趟（碰線）按一下大按鈕，App 會累計趟數、總距離與每趟秒數。"
                         : "設定單圈距離後開始計時，每跑完一圈按下大按鈕，App 會自動換算總距離與平均配速。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(mode == .shuttleRun ? "單趟距離" : "單圈距離")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 10) {
                        ForEach(mode == .shuttleRun ? [10.0, 20.0, 50.0, 100.0] : [200.0, 400.0, 800.0, 1000.0], id: \.self) { value in
                            Button {
                                engine.lapDistance = value
                                settings.lapDistance = value
                                CueService.shared.impact(.soft)
                            } label: {
                                Text("\(Int(value))m")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(engine.lapDistance == value
                                                  ? Theme.accent.opacity(0.3) : Color.white.opacity(0.06))
                                    )
                                    .foregroundStyle(engine.lapDistance == value ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("自訂距離…") { showDistanceSheet = true }
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }

            if pedometer.isAvailable {
                GlassCard {
                    Label("將同時使用 Core Motion 記錄步數與步頻", systemImage: "shoeprints.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var runningPanel: some View {
        VStack(spacing: 16) {
            GlassCard {
                VStack(spacing: 18) {
                    Text(Fmt.duration(engine.elapsed))
                        .font(.system(size: 62, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)

                    HStack {
                        StatPill(title: mode == .shuttleRun ? "趟數" : "圈數",
                             value: "\(engine.laps.count)", tint: Theme.amber)
                        StatPill(title: "距離（\(Fmt.distanceUnitLabel(settings.unit))）",
                                 value: Fmt.distanceValue(engine.totalDistance, unit: settings.unit),
                                 tint: Theme.accent)
                        StatPill(title: "平均配速",
                                 value: Fmt.pace(engine.averagePace, unit: settings.unit),
                                 tint: Theme.mint)
                    }

                    HStack {
                        StatPill(title: "本圈計時", value: Fmt.duration(engine.currentLapElapsed), tint: Theme.violet)
                        StatPill(title: "上一圈", value: Fmt.pace(engine.lastLapPace, unit: settings.unit), tint: Theme.textPrimary)
                        StatPill(title: "最佳圈", value: Fmt.pace(engine.bestLap?.pace, unit: settings.unit), tint: Theme.amber)
                    }

                    if pedometer.isActive {
                        HStack {
                            StatPill(title: "步數", value: "\(pedometer.steps)", tint: Theme.mint)
                            StatPill(title: "步頻", value: Fmt.decimal(pedometer.cadence, digits: 0), tint: Theme.mint)
                            StatPill(title: "計步距離",
                                     value: Fmt.distanceValue(pedometer.estimatedDistance, unit: settings.unit),
                                     tint: Theme.textSecondary)
                        }
                    }
                }
            }

            if !engine.laps.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(mode == .shuttleRun ? "分趟" : "分圈")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button {
                                engine.undoLastLap()
                            } label: {
                                Label("刪除上一圈", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .foregroundStyle(Theme.accentWarm)
                        }
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(engine.laps.reversed()) { lap in
                                    HStack {
                                        Text(mode == .shuttleRun ? "第 \(lap.number) 趟" : "第 \(lap.number) 圈")
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        Text(Fmt.duration(lap.duration))
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(Theme.accent)
                                        Text(Fmt.pace(lap.pace, unit: settings.unit))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(Theme.mint)
                                            .frame(width: 70, alignment: .trailing)
                                    }
                                    .padding(.vertical, 4)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                        }
                        .frame(maxHeight: 170)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.laps.count)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            switch engine.state {
            case .idle:
                Button {
                    engine.workoutType = mode
                    if mode == .shuttleRun, engine.lapDistance > 150 { engine.lapDistance = 20 }
                    engine.start()
                    pedometer.start()
                } label: {
                    Label(mode == .shuttleRun ? "開始折返跑" : "開始計圈", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

            case .running, .paused:
                Button {
                    engine.recordLap()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode == .shuttleRun ? "arrow.left.arrow.right" : "flag.checkered")
                            .font(.system(size: 34, weight: .bold))
                        Text(mode == .shuttleRun ? "計趟" : "計圈")
                            .font(.title3.weight(.bold))
                        Text(mode == .shuttleRun
                             ? "第 \(engine.laps.count + 1) 趟進行中"
                             : "第 \(engine.laps.count + 1) 圈進行中")
                            .font(.caption)
                            .opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Theme.accentGradient)
                    )
                }
                .buttonStyle(.plain)

                HStack(spacing: 14) {
                    Button {
                        engine.state == .running ? engine.pause() : engine.resume()
                    } label: {
                        Label(engine.state == .running ? "暫停" : "繼續",
                              systemImage: engine.state == .running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        showStopConfirm = true
                    } label: {
                        Label("結束", systemImage: "stop.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

            case .finished:
                EmptyView()
            }
        }
    }

    private var distanceSheet: some View {
        DistanceEditorSheet(title: "自訂圈距",
                            unit: settings.unit,
                            initialMeters: engine.lapDistance > 0 ? engine.lapDistance : settings.lapDistance,
                            suggestions: [50, 100, 200, 250, 300, 400, 800, 1000],
                            allowsOff: false) { value in
            engine.lapDistance = value
            settings.lapDistance = value
        }
    }

    private func finish() {
        engine.stop()
        pedometer.stop()
        let session = engine.buildSession(steps: pedometer.isAvailable ? pedometer.steps : nil,
                                          cadence: pedometer.isAvailable ? pedometer.cadence : nil)
        // 統一走 SessionSaver：儲存失敗會回報，也不會提早刪掉自動存檔
        if case .failed(let message) = SessionSaver.save(session, context: context) {
            saveErrorMessage = message
            return
        }
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
