import SwiftUI
import SwiftData

/// B5：間歇訓練計時器（不需定位）
struct IntervalTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var engine = IntervalTimerEngine()
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false

    private var phaseColor: Color {
        switch engine.phase {
        case .work: return Theme.accentWarm
        case .rest: return Theme.mint
        case .prepare: return Theme.amber
        case .finished: return Theme.accent
        case .idle: return Theme.accent
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [phaseColor.opacity(engine.isRunning ? 0.28 : 0.1), .clear],
                           center: .center, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: engine.phase)

            VStack(spacing: 18) {
                topBar
                if engine.phase == .idle {
                    configPanel
                } else {
                    timerPanel
                }
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .alert("結束訓練？", isPresented: $showStopConfirm) {
            Button("繼續", role: .cancel) {}
            Button("結束並儲存", role: .destructive) { finish() }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if engine.phase == .idle { dismiss() } else { showStopConfirm = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            Spacer()
            Text("室內間歇")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.top, 6)
    }

    private var configPanel: some View {
        VStack(spacing: 14) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("不需要定位權限", systemImage: "location.slash.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                    Text("設定衝刺與休息秒數、組數，計時器會用語音與震動提示切換。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            GlassCard {
                VStack(spacing: 14) {
                    stepperRow("預備", value: $engine.config.prepareSeconds, range: 0...60, step: 5, unit: "秒", tint: Theme.amber)
                    stepperRow("衝刺", value: $engine.config.workSeconds, range: 5...600, step: 5, unit: "秒", tint: Theme.accentWarm)
                    stepperRow("休息", value: $engine.config.restSeconds, range: 0...600, step: 5, unit: "秒", tint: Theme.mint)
                    stepperRow("組數", value: $engine.config.rounds, range: 1...50, step: 1, unit: "組", tint: Theme.accent)
                }
            }

            GlassCard {
                HStack {
                    Text("預估總時長")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Fmt.duration(TimeInterval(engine.config.totalSeconds)))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速範本")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 10) {
                        presetButton("Tabata", work: 20, rest: 10, rounds: 8)
                        presetButton("30/15", work: 30, rest: 15, rounds: 8)
                        presetButton("60/60", work: 60, rest: 60, rounds: 6)
                    }
                }
            }
        }
    }

    private func presetButton(_ title: String, work: Int, rest: Int, rounds: Int) -> some View {
        Button {
            engine.config.workSeconds = work
            engine.config.restSeconds = rest
            engine.config.rounds = rounds
            CueService.shared.impact(.soft)
        } label: {
            VStack(spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(work)/\(rest)×\(rounds)").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String, tint: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                CueService.shared.impact(.soft)
            } label: {
                Image(systemName: "minus.circle.fill").font(.title2).foregroundStyle(tint.opacity(0.8))
            }
            .buttonStyle(.plain)
            Text("\(value.wrappedValue)\(unit)")
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(tint)
                .frame(width: 70)
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                CueService.shared.impact(.soft)
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(tint.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private var timerPanel: some View {
        VStack(spacing: 22) {
            ZStack {
                RingProgress(progress: engine.phaseProgress,
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [phaseColor.opacity(0.4), phaseColor],
                                                       center: .center))
                VStack(spacing: 6) {
                    Text(engine.phase.displayName)
                        .font(.headline)
                        .foregroundStyle(phaseColor)
                    Text("\(Int(ceil(engine.remaining)))")
                        .font(.system(size: 78, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text("第 \(min(engine.currentRound, engine.config.rounds)) / \(engine.config.rounds) 組")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 280, height: 280)
            .padding(.top, 10)
            .scaleEffect(engine.phase == .work ? 1.02 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: engine.phase)

            HStack(spacing: 6) {
                ForEach(1...max(1, engine.config.rounds), id: \.self) { round in
                    Capsule()
                        .fill(round < engine.currentRound ? phaseColor
                              : (round == engine.currentRound ? phaseColor.opacity(0.6) : Color.white.opacity(0.12)))
                        .frame(height: 6)
                }
            }

            HStack {
                StatPill(title: "已進行", value: Fmt.duration(engine.totalElapsed), tint: Theme.textPrimary)
                StatPill(title: "剩餘組數",
                         value: "\(max(0, engine.config.rounds - engine.currentRound + 1))",
                         tint: Theme.accent)
                StatPill(title: "累積衝刺",
                         value: Fmt.duration(engine.completedWorkSeconds),
                         tint: Theme.accentWarm)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch engine.phase {
            case .idle:
                Button {
                    CueService.shared.configureAudioSession()
                    engine.start()
                } label: {
                    Label("開始訓練", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .finished:
                Button {
                    finish()
                } label: {
                    Label("儲存紀錄", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("重新開始") { engine.start() }
                    .buttonStyle(SecondaryButtonStyle())
            default:
                HStack(spacing: 14) {
                    Button {
                        engine.isPaused ? engine.resume() : engine.pause()
                    } label: {
                        Label(engine.isPaused ? "繼續" : "暫停",
                              systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        engine.skipPhase()
                    } label: {
                        Label("跳過", systemImage: "forward.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button {
                    showStopConfirm = true
                } label: {
                    Label("結束並儲存", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func finish() {
        engine.stop()
        let session = engine.buildSession()
        context.insert(session)
        try? context.save()
        finishedSession = session
    }
}
