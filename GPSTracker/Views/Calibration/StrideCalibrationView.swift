import SwiftUI
import SwiftData

struct StrideCalibrationView: View {
    @StateObject private var coordinator = CalibrationCoordinator.shared
    @StateObject private var importer = HealthKitImporter.shared
    @State private var profile: StrideProfile = .walking
    @State private var manualStride = 0.72
    @State private var revision = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("校正類型", selection: $profile) {
                    Text("走路").tag(StrideProfile.walking)
                    Text("跑步").tag(StrideProfile.running)
                    Text("負重行軍").tag(StrideProfile.ruck)
                }.pickerStyle(.segmented)
                modelCard
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("歷史紀錄全部保留；僅獨立實測且來源、時間與品質均通過的資料可訓練。每日總量、無定位估算與 GPS 補算不回灌模型。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Button("一鍵匯入並分析") { Task { await coordinator.run(importHealth: true) } }
                            .buttonStyle(PrimaryButtonStyle()).disabled(coordinator.isWorking || importer.isImporting)
                        Button("重新分析全部本機紀錄") { Task { await coordinator.run(importHealth: false) } }
                            .buttonStyle(SecondaryButtonStyle()).disabled(coordinator.isWorking || importer.isImporting)
                        if coordinator.isWorking {
                            ProgressView(value: importer.isImporting ? importer.progress : coordinator.progress)
                            Text(importer.isImporting ? importer.statusText : coordinator.stage).font(.caption)
                            Button("取消") { coordinator.cancel() }.buttonStyle(SecondaryButtonStyle())
                        }
                        if let latest = coordinator.latest {
                            Text(latest.message).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        NavigationLink("查看最近報告") { CalibrationReportsView() }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("手動微調（估算設定，不代表測量真值）").font(.headline)
                        Text(String(format: "%.3f 公尺／步", manualStride)).monospacedDigit()
                        Slider(value: $manualStride, in: profile == .running ? 0.3...2.8 : 0.3...1.5, step: 0.005)
                        Button("套用手動值") { StrideCalibration.setManual(manualStride, profile: profile); revision += 1 }
                            .buttonStyle(SecondaryButtonStyle())
                        if StrideCalibration.previous(profile) != nil {
                            Button("回退上一版模型") { StrideCalibration.rollback(profile); manualStride = StrideCalibration.stride(profile); revision += 1 }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }.padding(16)
        }.screenBackground().navigationTitle("步幅校正")
            .onAppear { manualStride = StrideCalibration.stride(profile) }
            .onChange(of: profile) { _, value in manualStride = StrideCalibration.stride(value) }
    }

    private var modelCard: some View {
        let _ = revision
        let state = StrideCalibration.state(profile)
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(state?.validation?.applied == true ? "已驗證個人模型" : state != nil ? "保守個人模型（尚未驗證）" : "系統／預設估算")
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                Text(String(format: "基礎步幅 %.3f 公尺／步", StrideCalibration.stride(profile)))
                Text("保留既有樣本：\(state?.sampleCount ?? 0) 筆；模型版本：\(state?.modelVersion ?? 0)")
                    .font(.caption)
                Text(String(format: "校正資料充分程度 %.0f%%（不是距離準確率）", (state?.confidence ?? 0) * 100)).font(.caption)
                if let validation = state?.validation, let error = validation.candidateError {
                    Text(String(format: "獨立測試 %d 場；平均相對誤差 %.1f%%；平均絕對誤差 %.1f m", validation.testCount, error * 100, validation.absoluteErrorMeters ?? 0)).font(.caption)
                } else { Text("尚未有足夠資料驗證").font(.caption).foregroundStyle(Theme.amber) }
                if profile == .ruck && state == nil {
                    Text("行軍資料不足：採一般步行基礎，尚未充分校正；負重與手機位置不作猜測。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Text("僅有整場距離／步數時使用保守平均步幅。走跑辨識可切換基礎模型；沒有對齊時間窗真值時不建立步頻曲線或手機位置修正。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct CalibrationReportsView: View {
    var body: some View {
        List {
            ForEach(CalibrationReportStore.reports) { report in
                Section(Fmt.dateTime(report.date)) {
                    Text(report.completed ? "分析完成｜判斷版本 \(report.version)" : "分析未完成，未套用模型")
                    Text("本機掃描 \(report.scanned) 筆（A/B/C/D 分母）")
                    if let healthScanned = report.healthScanned { Text("健康掃描 \(healthScanned)｜已有／重複 \(report.existing)｜新增 \(report.added)") }
                    Text("可訓練 \(report.eligible)｜待確認 \(report.pending)｜排除 \(report.excluded)｜資料不足／來源未知 \(report.insufficient)")
                    Text("A \(report.gradeCounts["A"] ?? 0) ／ B \(report.gradeCounts["B"] ?? 0) ／ C \(report.gradeCounts["C"] ?? 0) ／ D \(report.gradeCounts["D"] ?? 0)")
                    Text(report.message)
                    ForEach(report.sourceCounts.keys.sorted(), id: \.self) { key in Text("來源 \(key)：\(report.sourceCounts[key] ?? 0) 筆") }
                    ForEach(report.reasonCounts.keys.sorted(), id: \.self) { key in
                        Text("\(QualityReason(rawValue: key)?.label ?? key)：\(report.reasonCounts[key] ?? 0) 筆（可多原因）")
                    }
                    ForEach(report.outcomes.keys.sorted(), id: \.self) { key in
                        if let outcome = report.outcomes[key] {
                            Text("\(key)｜\(report.profileCounts[key] ?? 0) 筆候選｜\(outcome.reason)")
                            if let old = outcome.baselineError, let new = outcome.candidateError {
                                Text(String(format: "獨立測試 %d 場：舊 %.1f%% → 候選 %.1f%%，最差 %.1f%%，偏差 %+.1f%%", outcome.testCount, old * 100, new * 100, (outcome.worstRelativeError ?? 0) * 100, (outcome.signedRelativeError ?? 0) * 100))
                            }
                        }
                    }
                }.font(.caption)
            }
        }.navigationTitle("匯入分析報告")
    }
}

struct CalibrationEligibilityView: View {
    @Bindable var session: WorkoutSession
    @Environment(\.modelContext) private var context
    @State private var error: String?
    var body: some View {
        let decision = session.calibrationDecision ?? CalibrationDecision(grade: .c, eligible: false, reasons: [.missingData], gpsCoverage: nil, stride: nil)
        let e = session.evidence
        List {
            Section("訓練資格") {
                Text("品質 \(decision.grade.rawValue)｜\(decision.eligible ? "符合訓練候選資格" : "僅保留歷史展示")")
                Text("判斷版本 \(decision.version)｜\(Fmt.dateTime(decision.analyzedAt))")
                ForEach(decision.reasons, id: \.rawValue) { Text($0.label) }
                Text(decision.stride.map { String(format: "此場步幅 %.3f m", $0) } ?? "步幅資料不足")
                Text(decision.gpsCoverage.map { String(format: "GPS 有效覆蓋 %.1f%%", $0 * 100) } ?? "GPS 有效覆蓋不明")
                Toggle("排除此筆訓練", isOn: $session.trainingExcluded)
                    .onChange(of: session.trainingExcluded) { _, _ in
                        session.calibrationDecision = nil
                        do { try context.save(); Task { await CalibrationCoordinator.shared.run(importHealth: false) } }
                        catch { context.rollback(); error = error.localizedDescription }
                    }
                Text("取消排除仍須通過來源與品質安全門檻，並由獨立驗證決定是否更新模型。")
            }
            Section("來源與時間") {
                Text("\(Fmt.dateTime(session.startDate)) ～ \(Fmt.dateTime(session.endDate))")
                Text("距離：\(e.method.label)")
                Text("App：\(e.sourceBundle ?? session.sourceApp ?? "不明")")
                Text("裝置：\(e.device ?? "不明")")
                Text("步數來源：\(e.stepSource ?? "不明")｜時間對齊：\(e.stepsAligned ? "已確認" : "未確認")")
                Text("HealthKit UUID：\(e.workoutUUID ?? session.healthKitUUID ?? "無")")
                Text("原始場次：\(e.originSessionID ?? "不明")")
                Text("負重：\(session.loadWeight.map { String(format: "%.1f kg", $0) } ?? "未知")")
                Text("手機位置：\(e.carryPosition.label)")
            }
        }.font(.caption).navigationTitle("品質與訓練資格")
            .alert("儲存失敗", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}
