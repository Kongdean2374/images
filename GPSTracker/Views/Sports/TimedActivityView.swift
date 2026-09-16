import SwiftUI
import SwiftData

/// 通用計時記錄：球類、重訓、瑜伽、游泳等不需要 GPS 的項目都用這個。
struct TimedActivityView: View {
    let sport: SportKind
    /// 開啟該項目的獨立設定頁（由 DisciplineHostView 提供）
    var onSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var pedometer = PedometerManager()

    @State private var state: RunState = .idle
    @State private var startDate = Date()
    @State private var elapsed: TimeInterval = 0
    @State private var accumulated: TimeInterval = 0
    @State private var segmentStart: Date?
    @State private var timer: Timer?
    @State private var sets = 0
    @State private var distanceText = ""
    @State private var notes = ""
    @State private var intensity: Double = 1.0
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false

    private enum RunState { case idle, running, paused }

    private var tint: Color { Theme.color(for: sport.category) }

    private var manualDistance: Double? {
        guard let value = Double(distanceText), value > 0 else { return nil }
        return settings.unit == .metric ? value * 1000 : value * 1609.344
    }

    private var adjustedMET: Double {
        sport.met * intensity
    }

    private var calories: Double {
        IntensityCalculator.calories(met: adjustedMET,
                                     duration: elapsed,
                                     bodyWeight: settings.bodyWeight)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [tint.opacity(state == .running ? 0.25 : 0.08), .clear],
                           center: .top, startRadius: 10, endRadius: 500)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: state)

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 16) {
                        timerCard
                        if state == .idle { intensityCard } else { liveStatsCard }
                        setsCard
                        extrasCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 120)
                }
            }

            VStack {
                Spacer()
                controls
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .background(LinearGradient(colors: [.clear, Theme.bgBottom.opacity(0.95)],
                                               startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { stopTimer() }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .alert("結束這次\(sport.name)？", isPresented: $showStopConfirm) {
            Button("繼續", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finish() }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if state == .idle { dismiss() } else { showStopConfirm = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: sport.icon)
                    .foregroundStyle(tint)
                Text(sport.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            }
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
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var timerCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                Text(Fmt.duration(elapsed))
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    StatPill(title: "估算消耗", value: String(format: "%.0f", calories), tint: Theme.accentWarm)
                    StatPill(title: "MET", value: String(format: "%.1f", adjustedMET), tint: tint)
                    StatPill(title: "分類", value: sport.category.displayName, tint: Theme.textSecondary)
                }
                if state == .running {
                    Label("記錄中", systemImage: "record.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                } else if state == .paused {
                    Label("已暫停", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var intensityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("強度調整")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(intensityLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Slider(value: $intensity, in: 0.7...1.4, step: 0.05)
                    .tint(tint)
                Text("同一種運動強度差很多：休閒打球和比賽強度不同。這個倍率會直接影響熱量估算（基準 MET \(String(format: "%.1f", sport.met))）。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var intensityLabel: String {
        switch intensity {
        case ..<0.85: return "輕鬆"
        case ..<1.05: return "一般"
        case ..<1.25: return "認真"
        default: return "比賽強度"
        }
    }

    private var liveStatsCard: some View {
        GlassCard {
            HStack {
                StatPill(title: "步數",
                         value: pedometer.isAvailable ? "\(pedometer.steps)" : "--",
                         tint: Theme.mint)
                StatPill(title: "組數／局數", value: "\(sets)", tint: Theme.violet)
                StatPill(title: "開始時間", value: Fmt.dayTimeFormatter.string(from: startDate), tint: Theme.textSecondary)
            }
        }
    }

    private var setsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("組數 / 局數")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(sets)")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.violet)
                }
                HStack(spacing: 12) {
                    Button {
                        sets += 1
                        CueService.shared.impact(.light)
                    } label: {
                        Label("加一組", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        if sets > 0 { sets -= 1 }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 84)
                }
                Text("重訓可以記組數，球類可以記局數或場數，不需要就留 0。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var extrasCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("補充資訊（選填）")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    TextField("距離（\(Fmt.distanceUnitLabel(settings.unit))）", text: $distanceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                }
                Text("例如泳池游泳可以填總公尺數，室內飛輪可以填機器顯示的距離。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                TextField("備註", text: $notes)
                    .textFieldStyle(.plain)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch state {
            case .idle:
                Button { start() } label: {
                    Label("開始 \(sport.name)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .running, .paused:
                HStack(spacing: 14) {
                    Button {
                        state == .running ? pause() : resume()
                    } label: {
                        Label(state == .running ? "暫停" : "繼續",
                              systemImage: state == .running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        showStopConfirm = true
                    } label: {
                        Label("結束", systemImage: "stop.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    // MARK: 計時

    private func start() {
        startDate = Date()
        segmentStart = Date()
        accumulated = 0
        elapsed = 0
        sets = 0
        state = .running
        pedometer.start(from: startDate)
        if settings.keepScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            DispatchQueue.main.async {
                guard state == .running, let segmentStart else { return }
                elapsed = accumulated + Date().timeIntervalSince(segmentStart)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        CueService.shared.impact(.heavy)
        CueService.shared.speak("開始 \(sport.name)")
    }

    private func pause() {
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        segmentStart = nil
        elapsed = accumulated
        state = .paused
        CueService.shared.impact(.light)
    }

    private func resume() {
        segmentStart = Date()
        state = .running
        CueService.shared.impact(.light)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        pedometer.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finish() {
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        elapsed = max(accumulated, 1)
        stopTimer()
        state = .idle

        let session = WorkoutSession(type: .timedActivity,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: elapsed,
                                     totalDistance: manualDistance,
                                     averagePace: manualDistance.map { elapsed / ($0 / 1000) },
                                     stepCount: pedometer.isAvailable && pedometer.steps > 0 ? pedometer.steps : nil,
                                     distanceSource: manualDistance != nil ? .manual : nil,
                                     routeKey: sport.name,
                                     title: sport.name,
                                     notes: notes.isEmpty ? nil : notes)
        session.sport = sport
        session.setCount = sets > 0 ? sets : nil
        session.calories = calories
        session.intensityScore = IntensityCalculator.score(met: adjustedMET,
                                                           duration: elapsed,
                                                           distance: manualDistance,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
