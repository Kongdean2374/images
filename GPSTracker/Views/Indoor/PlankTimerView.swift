import SwiftUI
import SwiftData

/// 棒式／靜態撐體：計時 + 穩定度偵測，不需定位
struct PlankTimerView: View {
    /// 開啟該項目的獨立設定頁（由 DisciplineHostView 提供）
    var onSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]

    @StateObject private var engine = PlankEngine()
    @State private var exercise = "標準棒式"
    @State private var finishedSession: WorkoutSession?
    @State private var saveErrorMessage: String?

    private let exercises = ["標準棒式", "側棒式（左）", "側棒式（右）", "靠牆深蹲", "橋式"]
    private let targets = [30, 45, 60, 90, 120, 180]

    private var personalBest: TimeInterval? {
        sessions.filter { $0.type == .plank && $0.routeKey == exercise }
            .map { $0.duration }
            .max()
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.color(for: .plank).opacity(engine.state == .holding ? 0.25 : 0.08), .clear],
                           center: .center, startRadius: 10, endRadius: 440)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: engine.state)

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 16) {
                        if engine.state == .idle {
                            exercisePicker
                            targetCard
                            bestCard
                            tipCard
                        } else {
                            timerRing
                            stabilityCard
                            if engine.state == .finished { resultCard }
                        }
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
        .saveErrorAlert($saveErrorMessage)
        .onDisappear { engine.reset() }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            Spacer()
            Text("棒式撐體")
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
            else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var exercisePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(exercises, id: \.self) { item in
                    Button {
                        exercise = item
                        CueService.shared.impact(.soft)
                    } label: {
                        Text(item)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(exercise == item
                                                       ? Theme.color(for: .plank).opacity(0.3)
                                                       : Color.white.opacity(0.07)))
                            .foregroundStyle(exercise == item ? Theme.color(for: .plank) : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var targetCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("目標時間")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(Fmt.duration(TimeInterval(engine.targetSeconds)))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.color(for: .plank))
                }
                HStack(spacing: 8) {
                    ForEach(targets, id: \.self) { value in
                        Button {
                            engine.targetSeconds = value
                            CueService.shared.impact(.soft)
                        } label: {
                            Text(value >= 60 ? "\(value / 60)分\(value % 60 == 0 ? "" : "半")" : "\(value)s")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(engine.targetSeconds == value
                                                           ? Theme.color(for: .plank).opacity(0.3)
                                                           : Color.white.opacity(0.07)))
                                .foregroundStyle(engine.targetSeconds == value
                                                 ? Theme.color(for: .plank) : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle("姿勢散掉時自動結束", isOn: $engine.autoStopOnBreak)
                    .tint(Theme.color(for: .plank))
                    .foregroundStyle(Theme.textPrimary)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var bestCard: some View {
        if let best = personalBest {
            GlassCard {
                HStack {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("個人最佳・\(exercise)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(Fmt.duration(best))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var tipCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("怎麼放手機", systemImage: "iphone.gen3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("把手機放在腰背上或口袋裡，App 會用動作感測器判斷你有沒有撐穩。核心一鬆、腰塌下去時穩定度會掉，開啟自動結束就會停錶。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var timerRing: some View {
        VStack(spacing: 18) {
            ZStack {
                RingProgress(progress: engine.progress,
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [Theme.color(for: .plank).opacity(0.5),
                                                                Theme.color(for: .plank)],
                                                       center: .center))
                VStack(spacing: 4) {
                    Text(Fmt.duration(engine.elapsed))
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text("目標 \(Fmt.duration(TimeInterval(engine.targetSeconds)))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if engine.reachedTarget {
                        Label("已達標", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.mint)
                    }
                }
            }
            .frame(width: 270, height: 270)
            .padding(.top, 10)
        }
    }

    private var stabilityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("姿勢穩定度")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(engine.stabilityLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stabilityColor)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(stabilityColor)
                            .frame(width: geo.size.width * max(0.02, engine.stability))
                            .animation(.easeOut(duration: 0.25), value: engine.stability)
                    }
                }
                .frame(height: 10)
                if !engine.isAvailable {
                    Text("此裝置沒有動作感測器，僅計時。")
                        .font(.caption2)
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var stabilityColor: Color {
        switch engine.stability {
        case ..<0.4: return Theme.accentWarm
        case ..<0.7: return Theme.amber
        default: return Theme.mint
        }
    }

    private var resultCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                Text(engine.reachedTarget ? "達成目標！" : "這次撐了")
                    .font(.headline)
                    .foregroundStyle(engine.reachedTarget ? Theme.mint : Theme.textPrimary)
                Text(Fmt.duration(engine.elapsed))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                if let best = personalBest, engine.elapsed > best {
                    Label("刷新個人最佳", systemImage: "trophy.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            switch engine.state {
            case .idle:
                Button { engine.start() } label: {
                    Label("開始撐體", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .holding:
                Button { engine.stop() } label: {
                    Label("結束", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .finished:
                Button { save() } label: {
                    Label("儲存紀錄", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("再撐一次") { engine.start() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func save() {
        let session = engine.buildSession(exerciseName: exercise)
        // 統一走 SessionSaver：儲存失敗會回報，也不會提早刪掉自動存檔
        if case .failed(let message) = SessionSaver.save(session, context: context) {
            saveErrorMessage = message
            return
        }
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
