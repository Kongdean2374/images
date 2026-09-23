import SwiftUI
import SwiftData

/// B3：室內原地運動（加速度計 + 陀螺儀計次，不需定位）
/// 支援自訂動作庫與循環訓練（每組次數／組數／組間休息）。
struct IndoorRepsView: View {
    /// 開啟該項目的獨立設定頁（由 DisciplineHostView 提供）
    var onSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var detector = RepDetector()
    @StateObject private var pedometer = PedometerManager()
    @StateObject private var library = ExerciseLibrary.shared

    @State private var exercise: ExerciseItem = ExerciseItem.builtIn[0]
    @State private var circuit = CircuitConfig()
    @State private var startDate = Date()
    @State private var saveErrorMessage: String?
    @State private var elapsed: TimeInterval = 0
    @State private var isRunning = false
    @State private var timer: Timer?
    @State private var manualReps = 0
    @State private var completedSets = 0
    @State private var setBaseline = 0
    @State private var isResting = false
    @State private var restRemaining: TimeInterval = 0
    @State private var finishedSession: WorkoutSession?
    @State private var showAddExercise = false
    @State private var newName = ""
    @State private var newMET = "7.0"

    private var totalReps: Int { detector.repCount + manualReps }
    private var setReps: Int { max(0, totalReps - setBaseline) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    exercisePicker
                    if !isRunning { circuitCard }
                    counterCard
                    if isRunning && circuit.enabled { circuitProgressCard }
                    sensitivityCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 120)
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

            if isResting {
                restOverlay
            }
        }
        .preferredColorScheme(.dark)
        .saveErrorAlert($saveErrorMessage)
        .onAppear {
            if let first = library.items.first, !library.items.contains(exercise) {
                exercise = first
            }
            detector.sensitivity = exercise.sensitivity
        }
        .onDisappear {
            detector.stop()
            pedometer.stop()
            timer?.invalidate()
        }
        .onChange(of: totalReps) { _, _ in checkSetCompletion() }
        .sheet(isPresented: $showAddExercise) { addExerciseSheet }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
    }

    // MARK: 區塊

    private var topBar: some View {
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
            Text("原地運動")
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
                showAddExercise = true
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.top, 6)
    }

    private var exercisePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.items) { item in
                    Button {
                        guard !isRunning else { return }
                        exercise = item
                        detector.sensitivity = item.sensitivity
                        CueService.shared.impact(.soft)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.systemImage)
                            Text(item.name)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(exercise.id == item.id
                                           ? Theme.violet.opacity(0.35)
                                           : Color.white.opacity(0.07))
                        )
                        .foregroundStyle(exercise.id == item.id ? Theme.violet : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            library.remove(item)
                            if exercise.id == item.id, let first = library.items.first {
                                exercise = first
                            }
                        } label: {
                            Label("刪除動作", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var circuitCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $circuit.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("循環訓練")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("做滿一組自動進入休息倒數")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.violet)

                if circuit.enabled {
                    stepperRow("每組次數", value: $circuit.repsPerSet, range: 5...200, step: 5, unit: "下")
                    stepperRow("組數", value: $circuit.sets, range: 1...20, step: 1, unit: "組")
                    stepperRow("組間休息", value: $circuit.restSeconds, range: 0...300, step: 5, unit: "秒")
                    HStack {
                        Text("總計")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(circuit.totalReps) 下")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.violet)
                    }
                }
            }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                CueService.shared.impact(.soft)
            } label: {
                Image(systemName: "minus.circle.fill").font(.title2).foregroundStyle(Theme.violet.opacity(0.8))
            }
            .buttonStyle(.plain)
            Text("\(value.wrappedValue)\(unit)")
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(Theme.violet)
                .frame(width: 72)
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                CueService.shared.impact(.soft)
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.violet.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private var counterCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                Text("\(totalReps)")
                    .font(.system(size: 88, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.violet)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: totalReps)
                Text("下　（\(exercise.name)）")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    StatPill(title: "時間", value: Fmt.duration(elapsed), tint: Theme.textPrimary)
                    StatPill(title: "每分鐘",
                             value: elapsed > 5 ? String(format: "%.0f", Double(totalReps) / (elapsed / 60)) : "--",
                             tint: Theme.mint)
                    StatPill(title: "估算消耗",
                             value: String(format: "%.0f", exercise.met * settings.bodyWeight * (elapsed / 3600)),
                             tint: Theme.accentWarm)
                }

                HStack(spacing: 12) {
                    Button {
                        manualReps += 1
                        CueService.shared.impact(.light)
                    } label: {
                        Label("手動 +1", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        if manualReps > 0 { manualReps -= 1 }
                    } label: {
                        Label("－1", systemImage: "minus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var circuitProgressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("第 \(min(completedSets + 1, circuit.sets)) / \(circuit.sets) 組")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(setReps) / \(circuit.repsPerSet) 下")
                        .font(.subheadline.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.violet)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Theme.violet)
                            .frame(width: geo.size.width * min(1, Double(setReps) / Double(max(1, circuit.repsPerSet))))
                            .animation(.easeOut(duration: 0.3), value: setReps)
                    }
                }
                .frame(height: 8)
                HStack(spacing: 5) {
                    ForEach(1...max(1, circuit.sets), id: \.self) { index in
                        Capsule()
                            .fill(index <= completedSets ? Theme.violet : Color.white.opacity(0.12))
                            .frame(height: 5)
                    }
                }
            }
        }
    }

    private var sensitivityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("偵測靈敏度")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.2f g", detector.sensitivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $detector.sensitivity, in: 0.6...2.5)
                    .tint(Theme.violet)
                HStack(spacing: 6) {
                    Text("目前強度")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(Theme.violet)
                                .frame(width: min(geo.size.width, geo.size.width * detector.magnitude / 3))
                        }
                    }
                    .frame(height: 6)
                }
                if !detector.isAvailable {
                    Text("此裝置沒有可用的動作感測器，可改用手動 +1 計次。")
                        .font(.caption2)
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var restOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("休息")
                    .font(.headline)
                    .foregroundStyle(Theme.mint)
                Text("\(Int(ceil(restRemaining)))")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Text("下一組：第 \(min(completedSets + 1, circuit.sets)) / \(circuit.sets) 組")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("跳過休息") { endRest() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 200)
            }
        }
        .transition(.opacity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if isRunning {
                Button {
                    finish()
                } label: {
                    Label("結束並儲存", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    start()
                } label: {
                    Label("開始 \(exercise.name)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var addExerciseSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("動作名稱", text: $newName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                HStack {
                    Text("MET 值（強度）")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TextField("7.0", text: $newMET)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                }
                Text("MET 用來估算熱量：走路約 3.5、深蹲約 5.5、開合跳約 8、波比跳約 9.5。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Button("新增動作") {
                    library.add(name: newName, met: Double(newMET) ?? 7.0)
                    newName = ""
                    newMET = "7.0"
                    showAddExercise = false
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("恢復預設動作庫") {
                    library.resetToDefaults()
                    showAddExercise = false
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding()
            .screenBackground()
            .navigationTitle("自訂動作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showAddExercise = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: 流程

    private func start() {
        startDate = Date()
        elapsed = 0
        manualReps = 0
        completedSets = 0
        setBaseline = 0
        detector.reset()
        detector.start()
        pedometer.start()
        isRunning = true
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        CueService.shared.speak("開始，\(exercise.name)")
    }

    private func tick() {
        guard isRunning else { return }
        if isResting {
            restRemaining = max(0, restRemaining - 0.2)
            if restRemaining <= 0 { endRest() }
        } else {
            elapsed = Date().timeIntervalSince(startDate)
        }
    }

    private func checkSetCompletion() {
        guard isRunning, circuit.enabled, !isResting else { return }
        guard setReps >= circuit.repsPerSet else { return }
        completedSets += 1
        setBaseline = totalReps
        CueService.shared.notify(.success)

        if completedSets >= circuit.sets {
            CueService.shared.speak("全部 \(circuit.sets) 組完成")
            finish()
            return
        }
        if circuit.restSeconds > 0 {
            restRemaining = TimeInterval(circuit.restSeconds)
            withAnimation { isResting = true }
            detector.stop()
            CueService.shared.speak("第 \(completedSets) 組完成，休息 \(circuit.restSeconds) 秒")
        } else {
            CueService.shared.speak("第 \(completedSets) 組完成")
        }
    }

    private func endRest() {
        withAnimation { isResting = false }
        restRemaining = 0
        if isRunning {
            detector.start()
            CueService.shared.speak("開始第 \(completedSets + 1) 組")
            CueService.shared.impact(.heavy)
        }
    }

    private func finish() {
        detector.stop()
        pedometer.stop()
        timer?.invalidate()
        isRunning = false
        isResting = false

        let session = WorkoutSession(type: .indoorReps,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: elapsed,
                                     totalDistance: nil,
                                     averagePace: nil,
                                     stepCount: pedometer.isAvailable ? pedometer.steps : nil,
                                     repCount: totalReps,
                                     routeKey: exercise.name,
                                     title: exercise.name)
        session.calories = exercise.met * settings.bodyWeight * (elapsed / 3600)
        session.intensityScore = IntensityCalculator.score(type: .indoorReps,
                                                           duration: elapsed,
                                                           distance: nil,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        session.notes = circuit.enabled
            ? "\(exercise.name)　\(completedSets)/\(circuit.sets) 組　共 \(totalReps) 下"
            : "\(exercise.name) \(totalReps) 下"
        // 統一走 SessionSaver：儲存失敗會回報，也不會提早刪掉自動存檔
        if case .failed(let message) = SessionSaver.save(session, context: context) {
            saveErrorMessage = message
            return
        }
        Task { await HealthKitSync.syncIfEnabled(session) }
        finishedSession = session
    }
}
