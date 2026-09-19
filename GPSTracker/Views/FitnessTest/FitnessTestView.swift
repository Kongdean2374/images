import SwiftUI
import SwiftData

/// 體能測驗模式：2 分鐘仰臥起坐／伏地挺身、3000 公尺跑走。全程不需定位。
struct FitnessTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]

    @StateObject private var engine = FitnessTestEngine()
    @State private var standards = FitnessStandardsStore.load()
    @State private var selected: FitnessTestItem = .sitUps
    @State private var showStandardsEditor = false
    @State private var finishedSession: WorkoutSession?
    @State private var showQuitConfirm = false

    private var history: [WorkoutSession] {
        sessions.filter { $0.type == .fitnessTest && $0.routeKey == selected.displayName }
    }

    private var personalBest: Double? {
        let values: [Double] = history.compactMap { session in
            switch selected {
            case .cooper12: return session.totalDistance
            case .run3000: return session.duration > 0 ? session.duration : nil
            default: return session.repCount.map(Double.init)
            }
        }
        return selected.higherIsBetter ? values.max() : values.min()
    }

    /// 依項目格式化成績
    private func formatValue(_ value: Double) -> String {
        switch selected {
        case .cooper12: return "\(Int(value)) 公尺"
        case .run3000: return Fmt.duration(value)
        default: return "\(Int(value)) 下"
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch engine.phase {
            case .idle:
                setupScreen
            case .countdown:
                countdownScreen
            case .running:
                runningScreen
            case .finished:
                resultScreen
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { engine.reset() }
        .sheet(isPresented: $showStandardsEditor) {
            FitnessStandardsEditor(standards: $standards)
        }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
        .alert("放棄這次測驗？", isPresented: $showQuitConfirm) {
            Button("繼續測驗", role: .cancel) {}
            Button("放棄", role: .destructive) {
                engine.reset()
                dismiss()
            }
        }
    }

    // MARK: 設定畫面

    private var setupScreen: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                itemPicker
                standardCard
                if let best = personalBest {
                    bestCard(best)
                }
                howToCard
                Button {
                    engine.lapDistance = settings.lapDistance
                    engine.prepare(item: selected)
                } label: {
                    Label("開始測驗", systemImage: "flag.checkered")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            Spacer()
            Text("體能測驗")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                showStandardsEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.top, 6)
    }

    private var itemPicker: some View {
        VStack(spacing: 10) {
            ForEach(FitnessTestItem.allCases) { item in
                Button {
                    selected = item
                    CueService.shared.impact(.soft)
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(selected == item ? Theme.amber.opacity(0.25) : Color.white.opacity(0.06))
                            Image(systemName: item.systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(selected == item ? Theme.amber : Theme.textSecondary)
                        }
                        .frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(item == .run3000
                                 ? "計時到 3000 公尺，可手動計圈或用步幅估算"
                                 : "2 分鐘內盡可能多做，感測器自動計次")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if selected == item {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.amber)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(selected == item ? Theme.amber.opacity(0.6) : Theme.cardStroke,
                                            lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var standardCard: some View {
        let t = standards.thresholds(for: selected)
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("評等標準")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("編輯") { showStandardsEditor = true }
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                HStack(spacing: 8) {
                    thresholdPill("及格", t.pass)
                    thresholdPill("良", t.good)
                    thresholdPill("優", t.excellent)
                    thresholdPill("特優", t.elite)
                }
                Text("預設值為常見公開參考值，各單位與年齡組規定不同，請依你的最新規定自行調整。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func thresholdPill(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 3) {
            Text(formatValue(value))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func bestCard(_ best: Double) -> some View {
        GlassCard {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("個人最佳")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(formatValue(best))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Text(standards.grade(for: selected, value: best).displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.amber.opacity(0.2)))
                    .foregroundStyle(Theme.amber)
                Text("共 \(history.count) 次")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var howToCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("測驗方式", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if selected == .cooper12 {
                    Text("12 分鐘內盡可能跑遠。跑道每圈按一下「計圈」最準，沒有計圈時用你的個人步幅換算。結束後會依距離推估最大攝氧量。")
                } else if selected == .run3000 {
                    Text("把手機帶在身上，跑道每圈按一下「計圈」最準；沒有計圈時會用你的個人步幅換算距離。到 3000 公尺自動結束，每 500 公尺語音報時。")
                } else {
                    Text("手機放在身上（仰臥起坐建議放胸口口袋或手持，伏地挺身可放口袋），感測器自動計次；偵測不到的次數可以手動補。剩 1 分鐘、30 秒、10 秒會語音提醒，時間到自動結束。")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: 倒數

    private var countdownScreen: some View {
        VStack(spacing: 20) {
            Text("預備")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            Text("\(engine.countdown)")
                .font(.system(size: 140, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.amber)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: engine.countdown)
            Text(selected.displayName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Button("取消") { engine.reset() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 180)
        }
    }

    // MARK: 進行中

    private var runningScreen: some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    showQuitConfirm = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                Spacer()
                Text(selected.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            if selected == .cooper12 {
                cooperRunning
            } else if engine.isTimed {
                timedRunning
            } else {
                runRunning
            }

            Spacer()

            Button {
                engine.finish()
            } label: {
                Label("提前結束", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    private var timedRunning: some View {
        VStack(spacing: 22) {
            ZStack {
                RingProgress(progress: 1 - (engine.remaining / (selected.timeLimit ?? 120)),
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [Theme.amber.opacity(0.5), Theme.amber],
                                                       center: .center))
                VStack(spacing: 4) {
                    Text(Fmt.duration(engine.remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text("剩餘時間")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 250, height: 250)

            Text("\(engine.totalReps)")
                .font(.system(size: 78, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.amber)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: engine.totalReps)
            Text("下")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                Button {
                    engine.manualReps += 1
                    CueService.shared.impact(.light)
                } label: {
                    Label("補 +1", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    if engine.manualReps > 0 { engine.manualReps -= 1 }
                } label: {
                    Label("－1", systemImage: "minus")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 18)

            Text(gradePreview)
                .font(.caption)
                .foregroundStyle(Theme.mint)
        }
    }

    private var cooperRunning: some View {
        VStack(spacing: 20) {
            ZStack {
                RingProgress(progress: 1 - (engine.remaining / 720),
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [Theme.accent.opacity(0.5), Theme.accent],
                                                       center: .center))
                VStack(spacing: 4) {
                    Text("\(Int(engine.estimatedDistance))")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text("公尺")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text("剩 \(Fmt.duration(engine.remaining))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.amber)
                }
            }
            .frame(width: 250, height: 250)

            HStack {
                StatPill(title: "圈數", value: "\(engine.laps)", tint: Theme.amber)
                StatPill(title: "步數", value: "\(engine.pedometer.steps)", tint: Theme.mint)
                StatPill(title: "推估 VO₂max",
                         value: engine.vo2max.map { String(format: "%.1f", $0) } ?? "--",
                         tint: Theme.violet,
                         termID: "vo2max")
            }
            .padding(.horizontal, 18)

            HStack(spacing: 12) {
                Button {
                    engine.addLap()
                } label: {
                    Label("計圈（\(Int(engine.lapDistance))m）", systemImage: "flag.checkered")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    engine.removeLap()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 80)
            }
            .padding(.horizontal, 18)

            Text(gradePreview)
                .font(.caption)
                .foregroundStyle(Theme.mint)
        }
    }

    private var runRunning: some View {
        VStack(spacing: 20) {
            ZStack {
                RingProgress(progress: engine.runProgress,
                             lineWidth: 18,
                             gradient: AngularGradient(colors: [Theme.accent.opacity(0.5), Theme.accent],
                                                       center: .center))
                VStack(spacing: 4) {
                    Text(Fmt.duration(engine.elapsed))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: "%.0f / 3000 m", engine.estimatedDistance))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 250, height: 250)

            HStack {
                StatPill(title: "圈數", value: "\(engine.laps)", tint: Theme.amber)
                StatPill(title: "步數", value: "\(engine.pedometer.steps)", tint: Theme.mint)
                StatPill(title: "預估完成",
                         value: engine.runProgress > 0.05
                            ? Fmt.duration(engine.elapsed / max(0.05, engine.runProgress))
                            : "--",
                         tint: Theme.accent)
            }
            .padding(.horizontal, 18)

            HStack(spacing: 12) {
                Button {
                    engine.addLap()
                } label: {
                    Label("計圈（\(Int(engine.lapDistance))m）", systemImage: "flag.checkered")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    engine.removeLap()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 80)
            }
            .padding(.horizontal, 18)

            Text(gradePreview)
                .font(.caption)
                .foregroundStyle(Theme.mint)
        }
    }

    private var gradePreview: String {
        let grade = standards.grade(for: selected, value: engine.resultValue)
        if let next = standards.gapToNext(for: selected, value: engine.resultValue) {
            let gapText: String
            switch selected {
            case .cooper12: gapText = "再 \(Int(ceil(next.gap))) 公尺"
            case .run3000: gapText = "快 \(Fmt.duration(next.gap))"
            default: gapText = "再 \(Int(ceil(next.gap))) 下"
            }
            return "目前 \(grade.displayName)　距離「\(next.grade.displayName)」\(gapText)"
        }
        return "目前 \(grade.displayName)　已達最高等級"
    }

    // MARK: 結果

    private var resultScreen: some View {
        ScrollView {
            VStack(spacing: 18) {
                let value = engine.resultValue
                let grade = standards.grade(for: selected, value: value)

                VStack(spacing: 10) {
                    Image(systemName: "medal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.amber)
                    Text(grade.displayName)
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.amber)
                    Text(selected.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 30)

                GlassCard {
                    VStack(spacing: 16) {
                        ZStack {
                            RingProgress(progress: standards.progress(for: selected, value: value),
                                         lineWidth: 14)
                            VStack(spacing: 2) {
                                Text(selected == .run3000 ? Fmt.duration(value) : "\(Int(value))")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textPrimary)
                                Text(selected.unit)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: 150, height: 150)

                        if let vo2 = engine.vo2max {
                            HStack(spacing: 6) {
                                Image(systemName: "lungs.fill")
                                    .foregroundStyle(Theme.violet)
                                Text(String(format: "推估最大攝氧量 %.1f ml/kg/min・%@",
                                            vo2, FitnessTestItem.vo2maxLabel(vo2)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.violet)
                            }
                        }

                        if let next = standards.gapToNext(for: selected, value: value) {
                            Text("距離「\(next.grade.displayName)」還差 \(selected == .run3000 ? Fmt.duration(next.gap) : formatValue(next.gap))")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mint)
                        } else {
                            Text("已達最高等級")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mint)
                        }

                        if let best = personalBest {
                            let improved = selected.higherIsBetter ? value > best : value < best
                            Text(improved ? "刷新個人最佳！" : "個人最佳：\(formatValue(best))")
                                .font(.caption)
                                .foregroundStyle(improved ? Theme.amber : Theme.textSecondary)
                        }
                    }
                }

                if selected.tracksDistance {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("距離資料")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            HStack {
                                Text(engine.laps > 0 ? "手動計圈（最準）" : "個人步幅換算")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(String(format: "%.0f m", engine.estimatedDistance))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            if engine.laps == 0 {
                                Text("提醒：沒有計圈時距離是估算值，建議先到步幅校正頁把精準度拉高。")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                    }
                }

                Button {
                    save()
                } label: {
                    Label("儲存成績", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("重新測驗") { engine.reset() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
    }

    private func save() {
        let session = engine.buildSession(standards: standards)
        context.insert(session)
        try? context.save()
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}

/// 標準編輯器
struct FitnessStandardsEditor: View {
    @Binding var standards: FitnessStandards
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(FitnessTestItem.allCases) { item in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(item.displayName, systemImage: item.systemImage)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                thresholdEditor(item)
                            }
                        }
                    }
                    Button("恢復預設標準") {
                        standards = FitnessStandards()
                        FitnessStandardsStore.save(standards)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .screenBackground()
            .navigationTitle("評等標準")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        FitnessStandardsStore.save(standards)
                        dismiss()
                    }
                }
            }
        }
    }

    private func thresholdEditor(_ item: FitnessTestItem) -> some View {
        let t = standards.thresholds(for: item)
        return VStack(spacing: 10) {
            row(item, "及格", t.pass) { standards.set(FitnessThresholds(pass: $0, good: t.good, excellent: t.excellent, elite: t.elite), for: item) }
            row(item, "良", t.good) { standards.set(FitnessThresholds(pass: t.pass, good: $0, excellent: t.excellent, elite: t.elite), for: item) }
            row(item, "優", t.excellent) { standards.set(FitnessThresholds(pass: t.pass, good: t.good, excellent: $0, elite: t.elite), for: item) }
            row(item, "特優", t.elite) { standards.set(FitnessThresholds(pass: t.pass, good: t.good, excellent: t.excellent, elite: $0), for: item) }
        }
    }

    private func stepSize(_ item: FitnessTestItem) -> Double {
        switch item {
        case .cooper12: return 50
        case .run3000: return 5
        default: return 1
        }
    }

    private func row(_ item: FitnessTestItem, _ title: String, _ value: Double, update: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .leading)
            Spacer()
            Button {
                update(max(0, value - stepSize(item)))
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(Theme.accent.opacity(0.8))
            }
            .buttonStyle(.plain)
            Text(item == .run3000 ? Fmt.duration(value)
                 : (item == .cooper12 ? "\(Int(value)) m" : "\(Int(value)) 下"))
                .font(.subheadline.monospacedDigit())
                .frame(width: 92)
                .foregroundStyle(Theme.textPrimary)
            Button {
                update(value + stepSize(item))
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }
}
