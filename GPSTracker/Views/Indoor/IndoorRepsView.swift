import SwiftUI
import SwiftData

/// B3：室內原地運動（加速度計 + 陀螺儀計次，不需定位）
struct IndoorRepsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var detector = RepDetector()
    @StateObject private var pedometer = PedometerManager()

    @State private var exercise = "開合跳"
    @State private var startDate = Date()
    @State private var elapsed: TimeInterval = 0
    @State private var isRunning = false
    @State private var timer: Timer?
    @State private var manualReps = 0
    @State private var finishedSession: WorkoutSession?

    private let exercises = ["開合跳", "波比跳", "深蹲", "登山者", "高抬腿"]

    private var totalReps: Int { detector.repCount + manualReps }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                topBar
                exercisePicker
                counterCard
                sensitivityCard
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            detector.stop()
            pedometer.stop()
            timer?.invalidate()
        }
        .fullScreenCover(item: $finishedSession) { session in
            NavigationStack {
                WorkoutSummaryView(session: session, isNewlyFinished: true)
            }
            .onDisappear { dismiss() }
        }
    }

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
            Color.clear.frame(width: 42, height: 42)
        }
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
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(exercise == item ? Theme.violet.opacity(0.35) : Color.white.opacity(0.07))
                            )
                            .foregroundStyle(exercise == item ? Theme.violet : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var counterCard: some View {
        GlassCard {
            VStack(spacing: 18) {
                Text("\(totalReps)")
                    .font(.system(size: 92, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.violet)
                    .scaleEffect(isRunning ? 1 : 0.95)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: totalReps)
                Text("下　（\(exercise)）")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    StatPill(title: "時間", value: Fmt.duration(elapsed), tint: Theme.textPrimary)
                    StatPill(title: "每分鐘",
                             value: elapsed > 5 ? String(format: "%.0f", Double(totalReps) / (elapsed / 60)) : "--",
                             tint: Theme.mint)
                    StatPill(title: "估算消耗",
                             value: String(format: "%.0f", IntensityCalculator.calories(type: .indoorReps,
                                                                                        duration: elapsed,
                                                                                        bodyWeight: settings.bodyWeight)),
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
                    Label("開始", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func start() {
        startDate = Date()
        elapsed = 0
        manualReps = 0
        detector.reset()
        detector.start()
        pedometer.start()
        isRunning = true
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                self.elapsed = Date().timeIntervalSince(self.startDate)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        CueService.shared.speak("開始，\(exercise)")
    }

    private func finish() {
        detector.stop()
        pedometer.stop()
        timer?.invalidate()
        isRunning = false

        let session = WorkoutSession(type: .indoorReps,
                                     startDate: startDate,
                                     endDate: Date(),
                                     duration: elapsed,
                                     totalDistance: nil,
                                     averagePace: nil,
                                     stepCount: pedometer.isAvailable ? pedometer.steps : nil,
                                     repCount: totalReps,
                                     routeKey: exercise,
                                     title: exercise)
        session.calories = IntensityCalculator.calories(type: .indoorReps,
                                                        duration: elapsed,
                                                        bodyWeight: settings.bodyWeight)
        session.intensityScore = IntensityCalculator.score(type: .indoorReps,
                                                           duration: elapsed,
                                                           distance: nil,
                                                           averagePace: nil,
                                                           elevationGain: nil)
        session.notes = "\(exercise) \(totalReps) 下"
        context.insert(session)
        try? context.save()
        finishedSession = session
    }
}
