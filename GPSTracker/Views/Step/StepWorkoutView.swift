import SwiftUI
import SwiftData

/// 走路 / 跑步 / 跑步機：完全不需要定位權限。
struct StepWorkoutView: View {
    let initialMode: WorkoutType

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var engine = StepWorkoutEngine()
    @StateObject private var metronome = CadenceMetronome()
    @State private var targetKind = 0
    @State private var targetValue = ""
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false
    @State private var showTreadmillSheet = false
    @State private var actualDistanceText = ""

    private var modes: [WorkoutType] { [.walk, .run, .treadmill] }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.color(for: engine.mode).opacity(engine.state == .running ? 0.22 : 0.08), .clear],
                           center: .top, startRadius: 10, endRadius: 500)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: engine.state)

            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    if engine.state == .idle {
                        modePicker
                        targetCard
                        metronomeCard
                        infoCard
                        calibrationCard
                    } else {
                        if engine.target.isActive { targetProgressCard }
                        metricsCard
                        motionCard
                        metronomeCard
                        detailCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 130)
            }

            VStack {
                Spacer()
                controls
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .background(
                        LinearGradient(colors: [.clear, Theme.bgBottom.opacity(0.95)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                    )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { engine.mode = initialMode }
        .onDisappear {
            if engine.state == .running || engine.state == .paused { engine.stop() }
            metronome.stop()
        }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .alert("結束這次\(engine.mode.displayName)？", isPresented: $showStopConfirm) {
            Button("繼續", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finishFlow() }
        } message: {
            Text("已走 \(engine.steps) 步，約 \(Fmt.distance(engine.distance, unit: settings.unit))")
        }
        .sheet(isPresented: $showTreadmillSheet) { treadmillSheet }
    }

    // MARK: 區塊

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
            Label("免定位", systemImage: "location.slash.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.mint.opacity(0.15)))
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.top, 6)
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(modes) { mode in
                Button {
                    engine.mode = mode
                    CueService.shared.impact(.soft)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 24, weight: .semibold))
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(engine.mode == mode
                                  ? Theme.color(for: mode).opacity(0.25)
                                  : Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(engine.mode == mode ? Theme.color(for: mode) : .clear, lineWidth: 1.5)
                            )
                    )
                    .foregroundStyle(engine.mode == mode ? Theme.color(for: mode) : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }


    // MARK: 目標與節拍器

    private var selectedTarget: WorkoutTarget {
        guard let value = Double(targetValue), value > 0 else { return .none }
        switch targetKind {
        case 1: return .distance(settings.unit == .metric ? value * 1000 : value * 1609.344)
        case 2: return .steps(Int(value))
        case 3: return .duration(value * 60)
        case 4: return .calories(value)
        default: return .none
        }
    }

    private var targetCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("訓練目標")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Picker("目標類型", selection: $targetKind) {
                    Text("自由").tag(0)
                    Text("距離").tag(1)
                    Text("步數").tag(2)
                    Text("時間").tag(3)
                    Text("熱量").tag(4)
                }
                .pickerStyle(.segmented)

                if targetKind != 0 {
                    HStack {
                        TextField(placeholderForTarget, text: $targetValue)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                        Text(targetUnitLabel)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(quickTargets, id: \.self) { value in
                            Button {
                                targetValue = value
                                CueService.shared.impact(.soft)
                            } label: {
                                Text(value)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(targetValue == value
                                                               ? Theme.accent.opacity(0.3)
                                                               : Color.white.opacity(0.07)))
                                    .foregroundStyle(targetValue == value ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("達成時會語音與震動提醒，進行中也會顯示環形進度。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var placeholderForTarget: String {
        switch targetKind {
        case 1: return settings.unit == .metric ? "5" : "3"
        case 2: return "6000"
        case 3: return "40"
        case 4: return "300"
        default: return ""
        }
    }

    private var targetUnitLabel: String {
        switch targetKind {
        case 1: return Fmt.distanceUnitLabel(settings.unit)
        case 2: return "步"
        case 3: return "分鐘"
        case 4: return "大卡"
        default: return ""
        }
    }

    private var quickTargets: [String] {
        switch targetKind {
        case 1: return ["3", "5", "10", "21"]
        case 2: return ["3000", "6000", "10000", "15000"]
        case 3: return ["20", "30", "45", "60"]
        case 4: return ["150", "300", "500", "800"]
        default: return []
        }
    }

    private var targetProgressCard: some View {
        GlassCard {
            HStack(spacing: 18) {
                ZStack {
                    RingProgress(progress: engine.targetProgress, lineWidth: 11)
                    VStack(spacing: 1) {
                        Text(String(format: "%.0f%%", engine.targetProgress * 100))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.target.displayName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(engine.target.targetText(unit: settings.unit))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    if engine.targetReached {
                        Label("目標已達成", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.mint)
                    } else {
                        Text(engine.targetRemainingText)
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var metronomeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("步頻節拍器", systemImage: "metronome")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button {
                        metronome.toggle()
                    } label: {
                        Image(systemName: metronome.isRunning ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(metronome.isRunning ? Theme.accentWarm : Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Text(String(format: "%.0f BPM", metronome.bpm))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if engine.state != .idle {
                        Text(String(format: "目前步頻 %.0f", engine.cadence))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(engine.cadence > 0 && abs(engine.cadence - metronome.bpm) < 6
                                             ? Theme.mint : Theme.textSecondary)
                    }
                }
                Slider(value: $metronome.bpm, in: 120...200, step: 1)
                    .tint(Theme.accent)
                HStack(spacing: 8) {
                    ForEach([150.0, 165.0, 175.0, 180.0], id: \.self) { value in
                        Button {
                            metronome.bpm = value
                        } label: {
                            Text("\(Int(value))")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(abs(metronome.bpm - value) < 0.5
                                                           ? Theme.accent.opacity(0.3)
                                                           : Color.white.opacity(0.07)))
                                .foregroundStyle(abs(metronome.bpm - value) < 0.5 ? Theme.accent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 16) {
                    Toggle("聲音", isOn: $metronome.useSound)
                        .tint(Theme.accent)
                    Toggle("震動", isOn: $metronome.useHaptics)
                        .tint(Theme.accent)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                Text("跟著節拍踩步可以穩定步頻，減少受傷風險。多數跑者的舒適區間在 170～180 BPM。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var infoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("這個模式怎麼算距離")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Label("步數與步頻：iPhone 內建計步器（不需衛星訊號）", systemImage: "shoeprints.fill")
                Label("距離：優先用你的個人步幅換算，其次才用系統估算", systemImage: "ruler")
                Label("爬升與樓層：氣壓計，室內樓梯也抓得到", systemImage: "stairs")
                Label("走跑分段：動作辨識自動判斷", systemImage: "figure.walk.motion")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var calibrationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("個人步幅")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.2f 公尺/步", engine.strideLength))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.accent)
                }
                if engine.isCalibrated {
                    Label("已用 \(StrideCalibration.sampleCount(engine.strideProfile)) 次 GPS 紀錄校正過，距離會比系統估算準",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.mint)
                } else {
                    Label("尚未校正，目前使用平均值。跑一次 GPS 模式後會自動學習你的步幅。",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var metricsCard: some View {
        GlassCard {
            VStack(spacing: 18) {
                Text("\(engine.steps)")
                    .font(.system(size: 76, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.color(for: engine.mode))
                Text("步")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    StatPill(title: "時間", value: Fmt.duration(engine.elapsed), tint: Theme.textPrimary)
                    StatPill(title: "距離（\(Fmt.distanceUnitLabel(settings.unit))）",
                             value: Fmt.distanceValue(engine.distance, unit: settings.unit),
                             tint: Theme.accent)
                    StatPill(title: "配速",
                             value: Fmt.pace(engine.averagePace, unit: settings.unit),
                             tint: Theme.mint)
                }
                HStack {
                    StatPill(title: "步頻", value: Fmt.decimal(engine.cadence, digits: 0), tint: Theme.violet)
                    StatPill(title: "熱量", value: Fmt.decimal(engine.calories, digits: 0), tint: Theme.accentWarm)
                    StatPill(title: "樓層", value: "\(engine.floorsAscended)", tint: Theme.amber)
                }
            }
        }
    }

    private var motionCard: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: engine.currentMotion.systemImage)
                    .font(.title3)
                    .foregroundStyle(Theme.mint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("目前動作：\(engine.currentMotion.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    let durations = engine.motion.durations()
                    Text("走路 \(Fmt.duration(durations.walking))　跑步 \(Fmt.duration(durations.running))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detailCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("距離來源")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(engine.distanceSource.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                HStack {
                    Text("使用步幅")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(String(format: "%.2f m/步", engine.strideLength))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack {
                    Text("氣壓計爬升")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(engine.altimeter.isAvailable
                         ? String(format: "↑%.0f m　↓%.0f m", engine.elevationGain, engine.elevationLoss)
                         : "此裝置無氣壓計")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch engine.state {
            case .idle:
                Button {
                    engine.start(mode: engine.mode, target: selectedTarget)
                } label: {
                    Label("開始\(engine.mode.displayName)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .running, .paused:
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
                    .buttonStyle(PrimaryButtonStyle())
                }
            case .finished:
                EmptyView()
            }
        }
    }

    private var treadmillSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("輸入跑步機顯示的距離")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("輸入後會反推你的真實步幅，下次估算更準。留空則使用步數換算的 \(Fmt.distance(engine.distance, unit: settings.unit))。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                HStack {
                    TextField("例如 5.0", text: $actualDistanceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                    Text(Fmt.distanceUnitLabel(settings.unit))
                        .foregroundStyle(Theme.textSecondary)
                }
                Button("儲存紀錄") {
                    if let value = Double(actualDistanceText), value > 0 {
                        let meters = settings.unit == .metric ? value * 1000 : value * 1609.344
                        engine.applyActualDistance(meters)
                    }
                    showTreadmillSheet = false
                    save()
                }
                .buttonStyle(PrimaryButtonStyle())
                Spacer()
            }
            .padding()
            .screenBackground()
            .navigationTitle("跑步機校正")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(340)])
    }

    // MARK: 結束流程

    private func finishFlow() {
        engine.stop()
        if engine.mode == .treadmill {
            showTreadmillSheet = true
        } else {
            save()
        }
    }

    private func save() {
        let session = engine.buildSession()
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
