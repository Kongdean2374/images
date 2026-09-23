import SwiftUI
import ChaiNetCore

/// Runs one tool (or an arbitrary item set) independently. Leaving the screen cancels the run.
struct ToolRunView: View {
    let title: String
    let kind: TestKind
    let items: Set<TestItem>
    let symbol: String
    let explanation: String?

    @Environment(AppContainer.self) private var app
    @State private var vm: RunViewModel?

    init(tool: Tool) {
        title = tool.title
        kind = tool.kind
        items = tool.items
        symbol = tool.symbol
        explanation = tool.subtitle
    }

    init(title: String, kind: TestKind = .fullSpeedTest, items: Set<TestItem>, symbol: String = "slider.horizontal.3") {
        self.title = title
        self.kind = kind
        self.items = items
        self.symbol = symbol
        self.explanation = nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let vm {
                    content(vm)
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if vm == nil { vm = app.makeRunViewModel() } }
        .onDisappear { vm?.stop() }
    }

    @ViewBuilder
    private func content(_ vm: RunViewModel) -> some View {
        switch vm.status {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(Theme.accent).padding(.top, 24)
                if let explanation { Text(explanation).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center) }
                ToolLimitationNote(kind: kind, items: items)
                PrimaryButton(title: "開始", symbol: "play.fill") { start(vm) }
            }
        case .running:
            LiveRunView(vm: vm)
            if !vm.traceHops.isEmpty {
                TracerouteLive(hops: vm.traceHops)
            }
            Button(role: .destructive) { vm.stop() } label: { Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        case .finished, .cancelled:
            if let r = vm.result {
                ResultSummaryView(result: r)
                TechnicalDetailsView(result: r)
            }
            PrimaryButton(title: "再測一次", symbol: "arrow.clockwise") { start(vm) }
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "無法完成", message: message)
            PrimaryButton(title: "重試", symbol: "arrow.clockwise") { start(vm) }
        }
    }

    private func start(_ vm: RunViewModel) {
        vm.start(kind: kind, items: items, onCellular: app.onCellular)
    }
}

private struct TracerouteLive: View {
    let hops: [TracerouteHop]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hops) { hop in
                HStack {
                    Text("\(hop.ttl)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing)
                    Text(hop.address ?? "*").font(.caption.monospaced())
                    Spacer()
                    Text(Format.ms(hop.bestMs)).font(.caption.monospacedDigit())
                }
            }
        }
        .cardStyle()
    }
}

/// Explains platform limits before running, so the user knows what the tool can and can't see.
struct ToolLimitationNote: View {
    let kind: TestKind
    let items: Set<TestItem>

    var body: some View {
        if let text {
            Label(text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(padding: 12)
        }
    }

    private var text: String? {
        if items.contains(.traceroute) || items.contains(.mtu) {
            return "使用 ICMP datagram socket，目前僅支援 IPv4；部分路由器或網路會過濾 ICMP。"
        }
        if items.contains(.packetLoss) || kind == .gaming || kind == .voice {
            return "遺失率以 UDP echo（自架 ChaiNet 伺服器）或 ICMP 量測；TCP 會以重傳隱藏遺失，因此不使用 TCP。"
        }
        if items.contains(.interfaceCompare) {
            return "iOS 允許同時經由 Wi-Fi 與行動網路建立連線來比較延遲，但無法強制指定 LTE 或 5G。"
        }
        if items.contains(.ipFamilies) {
            return "延遲測試可指定 IPv4 / IPv6；下載 / 上傳由系統自動選擇（URLSession 限制）。"
        }
        return nil
    }
}
