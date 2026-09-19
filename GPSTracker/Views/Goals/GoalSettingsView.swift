import SwiftUI
import SwiftData

/// C7 目標設定
struct GoalSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var goals: [WorkoutGoal]
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings

    @State private var period: GoalPeriod = .weekly
    @State private var metric: GoalMetric = .distance
    @State private var targetText: String = "20"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("新增目標")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)

                        Picker("週期", selection: $period) {
                            ForEach(GoalPeriod.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        Picker("項目", selection: $metric) {
                            ForEach(GoalMetric.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            TextField("目標值", text: $targetText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                            Text(metric.unit)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Button {
                            addGoal()
                        } label: {
                            Label("新增", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }

                if goals.isEmpty {
                    Text("尚未設定任何目標")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 20)
                } else {
                    ForEach(goals) { goal in
                        goalRow(goal)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .screenBackground()
        .navigationTitle("目標設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func goalRow(_ goal: WorkoutGoal) -> some View {
        let progress = StatsEngine.progress(for: goal, sessions: sessions)
        return GlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RingProgress(progress: progress.fraction, lineWidth: 9)
                    Text(String(format: "%.0f%%", progress.fraction * 100))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 66, height: 66)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(goal.period.displayName)\(goal.metric.displayName)目標")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: "%.1f / %.0f %@", progress.current, progress.target, goal.metric.unit))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    if progress.fraction >= 1 {
                        Label("已達成", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.mint)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    context.delete(goal)
                    try? context.save()
                    CueService.shared.impact(.rigid)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.accentWarm)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addGoal() {
        guard let target = Double(targetText), target > 0 else { return }
        let goal = WorkoutGoal(period: period, metric: metric, target: target)
        context.insert(goal)
        try? context.save()
        CueService.shared.notify(.success)
    }
}
