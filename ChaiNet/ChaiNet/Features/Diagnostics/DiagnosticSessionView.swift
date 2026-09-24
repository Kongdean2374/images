import SwiftUI
import ChaiNetCore

struct DiagnosticSessionView: View {
    let initialSession: DiagnosticSession
    /// When set, this item set runs automatically once when the screen opens.
    let autoRun: Set<TestItem>?

    @Environment(AppContainer.self) private var app
    @State private var vm: DiagnosticSessionViewModel?
    @State private var didAutoRun = false
    @State private var showReport = false
    @State private var showHistoryPicker = false

    init(session: DiagnosticSession, autoRun: Set<TestItem>?) {
        self.initialSession = session
        self.autoRun = autoRun
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm { content(vm) } else { ProgressView() }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(vm?.session.title ?? initialSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .featureSettings("diagnostics", title: "診斷")
        .toolbar {
            if vm?.analysis != nil {
                Button { showReport = true } label: { Label("技術報告", systemImage: "doc.text") }
            }
        }
        .sheet(isPresented: $showReport) {
            if let report = vm?.makeReport() { NavigationStack { DiagnosticReportView(report: report) } }
        }
        .sheet(isPresented: $showHistoryPicker) {
            NavigationStack {
                HistoryPicker { result in
                    vm?.append(result, suffix: "歷史紀錄")
                    showHistoryPicker = false
                }
            }
        }
        .onAppear {
            if vm == nil { vm = DiagnosticSessionViewModel(session: initialSession, app: app) }
            if let autoRun, !didAutoRun, let vm, vm.session.tests.isEmpty {
                didAutoRun = true
                vm.addTest(items: autoRun)
            }
        }
        .onDisappear { vm?.stop() }
    }

    @ViewBuilder
    private func content(_ vm: DiagnosticSessionViewModel) -> some View {
        if vm.run.isRunning {
            VStack(alignment: .leading, spacing: 10) {
                Text("正在執行 \(vm.session.nextLabel)").font(.headline)
                LiveRunView(vm: vm.run)
                Button(role: .destructive) { vm.stop() } label: { Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        if case .failed(let message) = vm.run.status {
            Text("測試失敗：\(message)").font(.footnote).foregroundStyle(Theme.critical)
        }
        if let analysis = vm.analysis {
            ConclusionCard(analysis: analysis)
            HypothesisGroups(analysis: analysis)
            NextTestsCard(analysis: analysis, vm: vm)
            CrossTestCard(analysis: analysis)
            EvidenceCard(evidence: analysis.evidence)
        } else if !vm.run.isRunning {
            EmptyStateView(symbol: "scope", title: "尚無測試", message: "加入第一項測試後，診斷引擎會開始分析。")
        }
        TestsCard(vm: vm)
        AddTestMenu(vm: vm, showHistoryPicker: $showHistoryPicker)
    }
}

private struct ConclusionCard: View {
    let analysis: RootCauseAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let top = analysis.mostLikely {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最可能原因").font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(top.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(top.layer.displayName).font(.caption).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    ConfidenceRing(confidence: top.confidence, color: top.likelihood.color)
                }
            } else {
                Text("目前沒有達到「有可能」以上的單一原因").font(.headline)
            }
            Text(analysis.conclusion).font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}

struct ConfidenceRing: View {
    let confidence: Double
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 6)
            Circle().trim(from: 0, to: confidence).stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((confidence * 100).rounded()))%").font(.caption.weight(.bold).monospacedDigit())
        }
        .frame(width: 58, height: 58)
        .animation(.easeOut, value: confidence)
    }
}

private struct HypothesisGroups: View {
    let analysis: RootCauseAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("可能性高", analysis.likely, expanded: true)
            group("有可能", analysis.possible, expanded: false)
            group("證據不足", analysis.insufficient, expanded: false)
            group("未測試（不代表已排除）", analysis.notTested, expanded: false)
            group("可能性低", analysis.unlikely, expanded: false)
            group("已排除", analysis.ruledOut, expanded: false)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [DiagnosticHypothesis], expanded: Bool) -> some View {
        if !items.isEmpty {
            Text("\(title)（\(items.count)）").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(items) { HypothesisCard(hypothesis: $0, expanded: expanded) }
        }
    }
}

struct HypothesisCard: View {
    let hypothesis: DiagnosticHypothesis
    @State var expanded: Bool

    init(hypothesis: DiagnosticHypothesis, expanded: Bool) {
        self.hypothesis = hypothesis
        self._expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hypothesis.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Badge(text: hypothesis.likelihood.shortName, color: hypothesis.likelihood.color)
                            Text(hypothesis.layer.displayName).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(hypothesis.evidenceScore)").font(.headline.monospacedDigit()).foregroundStyle(hypothesis.likelihood.color)
                        Text("證據分數 · \(hypothesis.confidenceBand.displayName)").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            ProgressView(value: hypothesis.confidence).tint(hypothesis.likelihood.color)
            if expanded {
                if let reason = hypothesis.statusReason {
                    Text("狀態依據：\(reason)").font(.caption.weight(.medium)).foregroundStyle(hypothesis.likelihood.color)
                }
                Text(hypothesis.explanation).font(.caption).foregroundStyle(Theme.textSecondary)
                evidenceList("支持證據", hypothesis.supportingEvidence, "plus.circle.fill", Theme.critical)
                evidenceList("反向證據", hypothesis.contradictingEvidence, "minus.circle.fill", Theme.good)
                evidenceList("排除依據", hypothesis.rulingOutEvidence, "xmark.circle.fill", Theme.good)
                if !hypothesis.missingDimensions.isEmpty {
                    Text("缺少資料：" + hypothesis.missingDimensions.map(\.displayName).joined(separator: "、")).font(.caption).foregroundStyle(Theme.warning)
                }
                if !hypothesis.recommendedNextTests.isEmpty && hypothesis.likelihood != .ruledOut {
                    Text("驗證方式：" + hypothesis.recommendedNextTests.map(\.title).joined(separator: "；")).font(.caption).foregroundStyle(Theme.accent)
                }
                ForEach(hypothesis.limitations, id: \.self) { Text("限制：\($0)").font(.caption2).foregroundStyle(Theme.textSecondary) }
            }
        }
        .cardStyle(padding: 14)
    }

    @ViewBuilder
    private func evidenceList(_ title: String, _ items: [DiagnosticEvidence], _ symbol: String, _ color: Color) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold))
            ForEach(items) { e in
                Label { Text(e.statement).font(.caption) } icon: { Image(systemName: symbol).foregroundStyle(color).font(.caption) }
            }
        }
    }
}

private struct NextTestsCard: View {
    let analysis: RootCauseAnalysis
    let vm: DiagnosticSessionViewModel

    var body: some View {
        if !analysis.recommendedTests.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("建議的驗證測試").font(.headline)
                ForEach(analysis.recommendedTests.prefix(6)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.test.title).font(.subheadline.weight(.medium))
                            Spacer()
                            if let items = DiagnosticSessionViewModel.items(for: t.test) {
                                Button(DiagnosticSessionViewModel.isManual(t.test) ? "已切換，執行" : "執行") {
                                    vm.addTest(items: items, labelSuffix: t.test.title)
                                }
                                .buttonStyle(.bordered)
                                .disabled(vm.isRunning)
                            }
                        }
                        Text(t.test.howTo).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Divider()
                }
            }
            .cardStyle()
        }
    }
}

private struct CrossTestCard: View {
    let analysis: RootCauseAnalysis
    var body: some View {
        if let c = analysis.evidence.crossTest {
            TechnicalSection("交叉比較", symbol: "square.grid.3x3", expanded: false) {
                KeyValueRow(key: "多伺服器", value: serverText(c.servers.verdict))
                ForEach(c.servers.entries) { e in
                    KeyValueRow(key: "  \(e.name)", value: entryText(e),
                                valueColor: e.isAnomalous ? Theme.critical : (e.status == .notMeasured ? Theme.textSecondary : Theme.textPrimary))
                }
                KeyValueRow(key: "IPv4 / IPv6", value: ipText(c.ipFamilies.verdict))
                KeyValueRow(key: "網路類型", value: ifaceText(c.interfaces.verdict))
                ForEach(c.interfaces.groups) { g in
                    KeyValueRow(key: "  \(g.networkClass.displayName)", value: g.degraded ? "異常" : "正常", valueColor: g.degraded ? Theme.critical : Theme.good)
                }
                ForEach(Array(c.interfaces.unavailable.enumerated()), id: \.offset) { _, u in
                    KeyValueRow(key: "  \(u.networkClass.displayName)", value: "未測試（\(u.reason)）", valueColor: Theme.textSecondary)
                }
                KeyValueRow(key: "LTE / 5G", value: radioText(c.interfaces.radioVerdict))
            }
        }
    }

    func entryText(_ e: ServerComparisonEntry) -> String {
        switch e.status {
        case .notMeasured: return "未測試（\(e.unavailableReason ?? "無法連線")）"
        case .degraded: return "異常：\(e.reasons.joined(separator: "、"))"
        case .healthy:
            return "正常 · \(Format.ms(e.latencyMedianMs))" + (e.higherLatencyRelativeToPeers ? "（延遲高於其他端點，僅供參考）" : "")
        }
    }

    func serverText(_ v: ServerComparisonVerdict) -> String {
        switch v {
        case .insufficientData: "資料不足（需 ≥ 2 個端點）"
        case .allNormal: "全部正常"
        case .singleServerAnomalous: "僅單一伺服器異常"
        case .multipleServersAnomalous: "多個伺服器異常"
        case .allServersAnomalous: "全部伺服器異常"
        }
    }
    func ipText(_ v: IPFamilyVerdict) -> String {
        switch v {
        case .insufficientData: "資料不足"
        case .equivalent: "表現相近"
        case .ipv6Degraded: "僅 IPv6 劣化"
        case .ipv4Degraded: "僅 IPv4 劣化"
        case .bothDegraded: "兩者皆劣化"
        case .ipv6Unavailable: "IPv6 無法連線"
        }
    }
    func ifaceText(_ v: InterfaceVerdict) -> String {
        switch v {
        case .insufficientData: "資料不足（需兩種以上網路）"
        case .allNormal: "全部正常"
        case .wifiNormalCellularDegraded: "Wi-Fi 正常、行動網路異常"
        case .cellularNormalWifiDegraded: "行動網路正常、Wi-Fi 異常"
        case .allCellularDegradedWifiNormal: "LTE 與 5G 皆異常、Wi-Fi 正常"
        case .allDegraded: "全部異常"
        case .mixed: "混合"
        }
    }
    func radioText(_ v: RadioVerdict) -> String {
        switch v {
        case .insufficientData: "資料不足（需 LTE 與 5G 各一次）"
        case .bothNormal: "皆正常"
        case .lteNormalNRDegraded: "LTE 正常、5G 異常"
        case .nrNormalLTEDegraded: "5G 正常、LTE 異常"
        case .bothDegraded: "皆異常"
        }
    }
}

private struct EvidenceCard: View {
    let evidence: EvidenceSet
    var body: some View {
        TechnicalSection("全部證據（\(evidence.evidence.count)）", symbol: "list.bullet.clipboard", expanded: false) {
            ForEach(evidence.evidence) { e in
                Text("• \(e.statement)").font(.caption)
            }
            let missing = EvidenceDimension.allCases.filter { !evidence.measuredDimensions.contains($0) }
            if !missing.isEmpty {
                Text("尚未量測：" + missing.map(\.displayName).joined(separator: "、")).font(.caption2).foregroundStyle(Theme.warning)
            }
            ForEach(evidence.baselineComparisons.flatMap(\.anomalies)) { a in
                Text("⚠︎ 偏離基準：\(a.summary)").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

private struct TestsCard: View {
    let vm: DiagnosticSessionViewModel
    var body: some View {
        if !vm.session.tests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("工作階段中的測試").font(.headline)
                ForEach(vm.session.tests) { t in
                    let health = TestHealthEvaluator.assess(t.result)
                    NavigationLink { ResultDetailView(result: t.result) } label: {
                        HStack {
                            Image(systemName: health.isDegraded ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(health.isDegraded ? Theme.warning : Theme.good)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label).font(.subheadline).foregroundStyle(Theme.textPrimary)
                                Text(health.reasons.isEmpty ? Format.date(t.result.date) : health.reasons.joined(separator: "、"))
                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("從工作階段移除", role: .destructive) { vm.removeTest(id: t.id) } }
                }
            }
            .cardStyle()
        }
    }
}

private struct AddTestMenu: View {
    let vm: DiagnosticSessionViewModel
    @Binding var showHistoryPicker: Bool

    var body: some View {
        Menu {
            Button { vm.addTest(items: TestProfile.fullDiagnostics.items) } label: { Label("在目前網路執行完整診斷", systemImage: "stethoscope") }
            Button { vm.addTest(items: TestProfile.cellular.items.union([.ping]), labelSuffix: "快速") } label: { Label("在目前網路執行快速測試", systemImage: "bolt") }
            Button { vm.addTest(items: [.ping, .packetLoss, .jitter], ipPreference: .ipv4Only, labelSuffix: "僅 IPv4") } label: { Label("僅 IPv4 延遲 / 遺失", systemImage: "4.circle") }
            Button { vm.addTest(items: [.ping, .packetLoss, .jitter], ipPreference: .ipv6Only, labelSuffix: "僅 IPv6") } label: { Label("僅 IPv6 延遲 / 遺失", systemImage: "6.circle") }
            Button { vm.addTest(items: [.ping, .packetLoss, .crossValidation], labelSuffix: "多伺服器") } label: { Label("多伺服器交叉驗證", systemImage: "server.rack") }
            Button { vm.addTest(items: [.interfaceCompare, .ping], labelSuffix: "介面比較") } label: { Label("Wi-Fi / 行動網路同時比較", systemImage: "arrow.left.arrow.right") }
            Button { showHistoryPicker = true } label: { Label("從歷史紀錄加入", systemImage: "clock.arrow.circlepath") }
        } label: {
            Label("加入測試", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isRunning)
        Text("比較 LTE / 5G / Wi-Fi 時，請先在系統設定切換網路，再回來加入測試；iOS 不允許 App 自行切換。")
            .font(.caption2).foregroundStyle(Theme.textSecondary)
    }
}

/// Pick a past result to add to a session.
private struct HistoryPicker: View {
    let onPick: (TestResult) -> Void
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(app.history.results(limit: 100)) { r in
            Button { onPick(r) } label: { HistoryRow(result: r) }
        }
        .navigationTitle("選擇歷史紀錄")
        .toolbar { Button("取消") { dismiss() } }
    }
}
