import SwiftUI
import SwiftData

/// B5：間歇訓練（快速設定 or 自訂課表），不需定位
struct IntervalTimerView: View {
    /// 開啟該項目的獨立設定頁（由 DisciplineHostView 提供）
    var onSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var engine = IntervalTimerEngine()
    @StateObject private var store = IntervalPlanStore.shared
    @State private var finishedSession: WorkoutSession?
    @State private var showStopConfirm = false
    @State private var saveErrorMessage: String?
    @State private var useQuickSetup = true
    @State private var editingPlan: IntervalPlan?
    @State private var selectedPlanID: UUID?

    private var phaseColor: Color {
        switch engine.phase {
        case .work: return Theme.accentWarm
        case .rest: return Theme.mint
        case .prepare: return Theme.amber
        case .cooldown: return Theme.accent
        case .finished, .idle: return Theme.accent
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [phaseColor.opacity(engine.isRunning ? 0.28 : 0.1), .clear],
                           center: .center, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: engine.phase)

            VStack(spacing: 0) {
                topBar
                if engine.phase == .idle {
                    ScrollView {
                        VStack(spacing: 14) {
                            modeSwitch
                            if useQuickSetup { quickPanel } else { planPanel }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 120)
                    }
                } else {
                    ScrollView {
                        timerPanel
                            .padding(.horizontal, 18)
                            .padding(.bottom, 120)
                    }
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
        .sheet(item: $editingPlan) { plan in
            IntervalPlanEditor(plan: plan) { updated in
                store.save(updated)
            }
        }
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

    // MARK: 上方

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
            Text(engine.phase == .idle ? "間歇訓練" : (engine.planName.isEmpty ? "間歇訓練" : engine.planName))
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
            if engine.phase == .idle && !useQuickSetup {
                Button {
                    editingPlan = IntervalPlan(name: "新課表",
                                               segments: [IntervalSegment(kind: .work, seconds: 40),
                                                          IntervalSegment(kind: .rest, seconds: 20)],
                                               repeatCount: 6)
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var modeSwitch: some View {
        Picker("模式", selection: $useQuickSetup) {
            Text("快速設定").tag(true)
            Text("自訂課表").tag(false)
        }
        .pickerStyle(.segmented)
    }

    // MARK: 快速設定

    private var quickPanel: some View {
        VStack(spacing: 14) {
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
                    Label("預估總時長", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Fmt.duration(TimeInterval(engine.config.totalSeconds)))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
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

    // MARK: 課表

    private var planPanel: some View {
        VStack(spacing: 12) {
            ForEach(store.plans) { plan in
                Button {
                    selectedPlanID = plan.id
                    CueService.shared.impact(.soft)
                } label: {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(plan.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if selectedPlanID == plan.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            Text(plan.summary)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            segmentBar(plan)
                            HStack(spacing: 14) {
                                Button {
                                    editingPlan = plan
                                } label: {
                                    Label("編輯", systemImage: "slider.horizontal.3")
                                        .font(.caption)
                                }
                                .foregroundStyle(Theme.accent)
                                Button(role: .destructive) {
                                    store.delete(plan)
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                        .font(.caption)
                                }
                                .foregroundStyle(Theme.accentWarm)
                                Spacer()
                                Text("衝刺 \(Fmt.duration(TimeInterval(plan.workSeconds)))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.mint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Button("恢復預設課表") { store.resetToPresets() }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// 課表結構的視覺化長條
    private func segmentBar(_ plan: IntervalPlan) -> some View {
        let total = max(1, plan.segments.reduce(0) { $0 + $1.seconds })
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(plan.segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: segment.kind))
                        .frame(width: max(3, geo.size.width * Double(segment.seconds) / Double(total)))
                }
            }
        }
        .frame(height: 10)
    }

    private func color(for kind: IntervalSegmentKind) -> Color {
        switch kind {
        case .prepare: return Theme.amber
        case .work: return Theme.accentWarm
        case .rest: return Theme.mint
        case .cooldown: return Theme.accent
        }
    }

    // MARK: 進行中

    private var timerPanel: some View {
        VStack(spacing: 20) {
            ZStack {
                RingProgress(progress: engine.phaseProgress,
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [phaseColor.opacity(0.4), phaseColor],
                                                       center: .center))
                VStack(spacing: 6) {
                    Text(engine.currentSegmentName.isEmpty ? engine.phase.displayName : engine.currentSegmentName)
                        .font(.headline)
                        .foregroundStyle(phaseColor)
                    Text("\(Int(ceil(engine.remaining)))")
                        .font(.system(size: 78, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text("第 \(engine.stepIndex + 1) / \(engine.stepCount) 段")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 280, height: 280)
            .padding(.top, 8)
            .scaleEffect(engine.phase == .work ? 1.02 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: engine.phase)

            VStack(spacing: 6) {
                HStack {
                    Text("整體進度")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f%%", engine.overallProgress * 100))
                        .font(.caption.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.accent)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Theme.accentGradient)
                            .frame(width: geo.size.width * max(0.01, engine.overallProgress))
                            .animation(.easeOut(duration: 0.3), value: engine.overallProgress)
                    }
                }
                .frame(height: 8)
            }

            HStack {
                StatPill(title: "已進行", value: Fmt.duration(engine.totalElapsed), tint: Theme.textPrimary)
                StatPill(title: "輪次", value: "\(engine.currentRound) / \(engine.totalRounds)", tint: Theme.accent)
                StatPill(title: "累積衝刺", value: Fmt.duration(engine.completedWorkSeconds), tint: Theme.accentWarm)
            }
        }
    }

    // MARK: 控制

    private var controls: some View {
        VStack(spacing: 12) {
            switch engine.phase {
            case .idle:
                Button {
                    CueService.shared.configureAudioSession()
                    if useQuickSetup {
                        engine.start()
                    } else if let id = selectedPlanID ?? store.plans.first?.id,
                              let plan = store.plans.first(where: { $0.id == id }) {
                        engine.start(plan: plan)
                    }
                } label: {
                    Label("開始訓練", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .finished:
                Button { finish() } label: {
                    Label("儲存紀錄", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("重新開始") {
                    if useQuickSetup {
                        engine.start()
                    } else if let id = selectedPlanID, let plan = store.plans.first(where: { $0.id == id }) {
                        engine.start(plan: plan)
                    }
                }
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
        // 統一走 SessionSaver：儲存失敗會回報，也不會提早刪掉自動存檔
        if case .failed(let message) = SessionSaver.save(session, context: context) {
            saveErrorMessage = message
            return
        }
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}

/// 課表編輯器
struct IntervalPlanEditor: View {
    @State var plan: IntervalPlan
    let onSave: (IntervalPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("課表名稱")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            TextField("課表名稱", text: $plan.name)
                                .textFieldStyle(.plain)
                                .padding(11)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                            HStack {
                                Text("重複輪數")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Button {
                                    plan.repeatCount = max(1, plan.repeatCount - 1)
                                } label: {
                                    Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                                Text("\(plan.repeatCount)")
                                    .font(.headline.monospacedDigit())
                                    .frame(width: 44)
                                    .foregroundStyle(Theme.accent)
                                Button {
                                    plan.repeatCount = min(50, plan.repeatCount + 1)
                                } label: {
                                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            HStack {
                                Text("總時長")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(Fmt.duration(TimeInterval(plan.totalSeconds)))
                                    .font(.subheadline.monospacedDigit())
                                    .contentTransition(.numericText())
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }

                    ForEach($plan.segments) { $segment in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Picker("類型", selection: $segment.kind) {
                                        ForEach(IntervalSegmentKind.allCases) { kind in
                                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(Theme.accent)
                                    Spacer()
                                    Button(role: .destructive) {
                                        plan.segments.removeAll { $0.id == segment.id }
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(Theme.accentWarm)
                                    }
                                    .buttonStyle(.plain)
                                }
                                TextField("名稱", text: $segment.name)
                                    .textFieldStyle(.plain)
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                                HStack {
                                    Text("秒數")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Button {
                                        segment.seconds = max(5, segment.seconds - 5)
                                    } label: {
                                        Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(Theme.mint)
                                    }
                                    .buttonStyle(.plain)
                                    Text("\(segment.seconds)s")
                                        .font(.headline.monospacedDigit())
                                        .frame(width: 60)
                                        .foregroundStyle(Theme.mint)
                                    Button {
                                        segment.seconds = min(900, segment.seconds + 5)
                                    } label: {
                                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Theme.mint)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Button {
                        plan.segments.append(IntervalSegment(kind: .work, seconds: 30))
                    } label: {
                        Label("新增一段", systemImage: "plus.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .screenBackground()
            .navigationTitle("編輯課表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("儲存") {
                        onSave(plan)
                        dismiss()
                    }
                    .disabled(plan.segments.isEmpty)
                }
            }
        }
    }
}
