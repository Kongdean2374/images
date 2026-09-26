import SwiftUI
import SwiftData
import Charts

/// 步幅校正中心：一鍵從健康 App 的歷史資料自動計算，並顯示精準度。
private struct SourceRow: Identifiable {
    let id = UUID()
    let source: StrideSample.Source
    let count: Int
}

struct StrideCalibrationView: View {
    @Query(sort: \WorkoutSession.startDate, order: .reverse) private var sessions: [WorkoutSession]
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var health = HealthKitManager.shared

    @State private var profile: StrideProfile = .walking
    @State private var isCalculating = false
    @State private var progressText = ""
    @State private var results: [StrideProfile: CalibrationResult] = [:]
    @State private var samples: [StrideSample] = []
    @State private var message: String?
    @State private var manualStride: Double = 0.72

    private var current: CalibrationResult? { results[profile] }

    private var storedConfidence: Double { StrideCalibration.confidence(profile) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                profilePicker
                accuracyCard
                autoCalculateCard
                if let current { breakdownCard(current) }
                if !samples.isEmpty { distributionCard }
                manualCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("步幅校正")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            health.refreshAvailability()
            manualStride = StrideCalibration.stride(profile)
        }
        .onChange(of: profile) { _, newValue in
            manualStride = StrideCalibration.stride(newValue)
        }
    }

    // MARK: 區塊

    private var profilePicker: some View {
        Picker("類型", selection: $profile) {
            Text("走路").tag(StrideProfile.walking)
            Text("跑步").tag(StrideProfile.running)
        }
        .pickerStyle(.segmented)
    }

    private var accuracyCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                ZStack {
                    RingProgress(progress: displayConfidence,
                                 lineWidth: 16,
                                 gradient: AngularGradient(colors: confidenceColors, center: .center))
                    VStack(spacing: 2) {
                        Text("\(Int((displayConfidence * 100).rounded()))%")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 4) {
                            Text("精準度")
                            GlossaryButton(termID: "strideConfidence", size: 12)
                        }
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 168, height: 168)
                .padding(.top, 4)

                Text(gradeText)
                    .font(.headline)
                    .foregroundStyle(confidenceColor)

                HStack {
                    StatPill(title: "目前步幅",
                             value: String(format: "%.3f", displayStride),
                             tint: Theme.accent)
                    StatPill(title: "樣本數",
                             value: "\(current?.rawSampleCount ?? StrideCalibration.sampleCount(profile))",
                             tint: Theme.mint)
                    StatPill(title: "資料跨度",
                             value: spanText,
                             tint: Theme.amber)
                }

                Text(adviceText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let updated = StrideCalibration.lastUpdated(profile) {
                    Text("最後更新：\(Fmt.dateTime(updated))　方式：\(methodText)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var autoCalculateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("自動計算")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("一次讀取健康 App 過去數年的步數與距離，加上本 App 的 GPS 紀錄，算出你的真實步幅。越近期的資料權重越高，三、四年前的舊資料只作參考。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if !health.isReady {
                    Label(health.availability.displayName, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                    Text("沒有健康權限時，仍可只用 App 內的 GPS 紀錄計算，樣本較少、精準度較低。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                if isCalculating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.mint)
                }

                Button {
                    Task { await calculate() }
                } label: {
                    Label(health.isReady ? "從健康 App 自動計算" : "授權並自動計算",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isCalculating)

                if current != nil {
                    Button {
                        applyResults()
                    } label: {
                        Label("套用這次計算結果", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func breakdownCard(_ result: CalibrationResult) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                GlossaryHeader(title: "精準度組成", termID: "strideConfidence")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                factorRow("資料量", result.coverageScore, weight: "50%",
                          detail: String(format: "有效樣本 %.1f（原始 %d 筆）", result.weightedSampleCount, result.rawSampleCount))
                factorRow("一致性", result.consistency, weight: "30%",
                          detail: String(format: "變異係數 %.1f%%", result.coefficientOfVariation * 100))
                factorRow("新鮮度", result.recencyScore, weight: "20%",
                          detail: result.newestDate.map { "最近資料 \(Fmt.date($0))" } ?? "--")

                Divider().overlay(Color.white.opacity(0.08))

                HStack {
                    Text("資料來源")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                ForEach(sourceRows(result)) { row in
                    HStack {
                        Text(row.source.displayName)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(row.count) 筆")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let oldest = result.oldestDate, let newest = result.newestDate {
                    Text("涵蓋 \(Fmt.date(oldest)) ～ \(Fmt.date(newest))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func sourceRows(_ result: CalibrationResult) -> [SourceRow] {
        result.sourceBreakdown
            .map { SourceRow(source: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func factorRow(_ title: String, _ value: Double, weight: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("佔 \(weight)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.subheadline.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(color(for: value))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(color(for: value))
                        .frame(width: geo.size.width * min(1, max(0.01, value)))
                        .animation(.easeOut(duration: 0.5), value: value)
                }
            }
            .frame(height: 6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var distributionCard: some View {
        let profileSamples = samples.filter { $0.profile == profile }
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("樣本分佈")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("每個點是一次可用的資料，橫軸為日期、縱軸為當次算出的步幅。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                if profileSamples.isEmpty {
                    Text("這個類型還沒有可用樣本。")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                } else {
                    Chart {
                        ForEach(profileSamples) { sample in
                            PointMark(x: .value("日期", sample.date),
                                      y: .value("步幅", sample.stride))
                            .foregroundStyle(Theme.accent.opacity(0.35 + 0.6 * sample.weight))
                            .symbolSize(28)
                        }
                        if let current {
                            RuleMark(y: .value("採用值", current.stride))
                                .foregroundStyle(Theme.mint)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .annotation(position: .top, alignment: .leading) {
                                    Text(String(format: "採用 %.3f m", current.stride))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.mint)
                                }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(String(format: "%.2f", v))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(Fmt.shortDayFormatter.string(from: date))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 190)
                }
            }
        }
    }

    private var manualCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("手動微調")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Text("步幅")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(String(format: "%.3f 公尺/步", manualStride))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: $manualStride, in: 0.40...1.80, step: 0.005)
                    .tint(Theme.accent)
                HStack(spacing: 12) {
                    Button("套用手動值") {
                        StrideCalibration.setManual(manualStride, profile: profile)
                        message = "已套用手動步幅"
                        CueService.shared.notify(.success)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("重設此類型") {
                        StrideCalibration.reset(profile)
                        results[profile] = nil
                        manualStride = StrideCalibration.defaultStride(profile)
                        message = "已重設"
                        CueService.shared.impact(.rigid)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text("手動設定後精準度會固定在中等，之後每次 GPS 運動仍會微幅修正。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: 計算

    @MainActor
    private func calculate() async {
        isCalculating = true
        message = nil
        defer { isCalculating = false }

        var collected: [StrideSample] = []

        progressText = "讀取 App 內的紀錄…"
        collected.append(contentsOf: StrideAutoCalibrator.samples(from: sessions))

        if !health.isReady {
            progressText = "請求健康權限…"
            let granted = await health.requestAuthorization()
            if granted { AppSettings.shared.healthKitEnabled = true }
        }

        if health.isReady {
            progressText = "讀取健康 App 每日步數與距離…"
            collected.append(contentsOf: await health.dailyStrideSamples(days: 1095))
            progressText = "讀取歷史體能訓練…"
            collected.append(contentsOf: await health.workoutStrideSamples(limit: 80, years: 5))
        }

        progressText = "計算中…"
        samples = collected
        let walking = StrideAutoCalibrator.compute(samples: collected, profile: .walking)
        let running = StrideAutoCalibrator.compute(samples: collected, profile: .running)
        results = [.walking: walking, .running: running]

        if collected.isEmpty {
            message = health.isReady
                ? "健康 App 裡沒有足夠的步數與距離資料。"
                : "沒有健康權限，且 App 內也還沒有含步數的 GPS 紀錄。"
        } else {
            applyResults()
            message = String(format: "已分析 %d 筆資料，走路精準度 %d%%、跑步精準度 %d%%",
                             collected.count, walking.confidencePercent, running.confidencePercent)
            CueService.shared.notify(.success)
        }
    }

    private func applyResults() {
        for (_, result) in results where result.rawSampleCount > 0 {
            StrideCalibration.apply(result)
        }
        manualStride = StrideCalibration.stride(profile)
    }

    // MARK: 顯示輔助

    private var displayConfidence: Double {
        current?.confidence ?? storedConfidence
    }

    private var displayStride: Double {
        current?.stride ?? StrideCalibration.stride(profile)
    }

    private var confidenceColor: Color {
        color(for: displayConfidence)
    }

    private var confidenceColors: [Color] {
        [confidenceColor.opacity(0.5), confidenceColor]
    }

    private func color(for value: Double) -> Color {
        switch value {
        case ..<0.25: return Theme.accentWarm
        case ..<0.5: return Theme.amber
        case ..<0.75: return Theme.accent
        default: return Theme.mint
        }
    }

    private var gradeText: String {
        if let current { return current.grade }
        switch storedConfidence {
        case 0: return "尚未校正"
        case ..<0.25: return "資料不足"
        case ..<0.5: return "粗略"
        case ..<0.75: return "堪用"
        case ..<0.9: return "良好"
        default: return "非常準確"
        }
    }

    private var adviceText: String {
        if let current { return current.advice }
        if storedConfidence > 0 {
            return "已有校正結果。按「自動計算」重新分析健康 App 的最新資料，可讓數值更貼近現在的你。"
        }
        return "還沒有校正過。按「自動計算」讓 App 讀取你過去的運動資料推算步幅。"
    }

    private var spanText: String {
        if let current, current.spanDays > 0 {
            if current.spanDays >= 365 {
                return String(format: "%.1f 年", Double(current.spanDays) / 365)
            }
            return "\(current.spanDays) 天"
        }
        let stored = StrideCalibration.state(profile)?.spanDays ?? 0
        return stored > 0 ? "\(stored) 天" : "--"
    }

    private var methodText: String {
        switch StrideCalibration.method(profile) {
        case "auto": return "自動計算"
        case "learn": return "逐次學習"
        case "manual": return "手動設定"
        default: return "--"
        }
    }
}
