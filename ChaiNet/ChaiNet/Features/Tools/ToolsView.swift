import SwiftUI
import ChaiNetCore

struct ToolsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NavigationLink { StressTestView() } label: {
                    HStack {
                        Image(systemName: "flame.fill").font(.title2).foregroundStyle(Theme.critical)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("極限壓力測試").font(.headline).foregroundStyle(Theme.textPrimary)
                            Text("最大負載 · 多節點 · 多輪 · 只需選擇時間 · AI / Engineer 匯出").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                    }
                    .cardStyle()
                }
                .buttonStyle(.plain)

                NavigationLink { CustomTestView() } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自訂測試").font(.headline).foregroundStyle(Theme.textPrimary)
                            Text("勾選項目組合一次性測試，或儲存為測試設定檔").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                    }
                    .cardStyle()
                }
                .buttonStyle(.plain)

                ForEach(Tool.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        VStack(spacing: 0) {
                            ForEach(Tool.allCases.filter { $0.group == group }) { tool in
                                NavigationLink { destination(tool) } label: { ToolRow(tool: tool) }
                                    .buttonStyle(.plain)
                                if tool != Tool.allCases.last(where: { $0.group == group }) { Divider().padding(.leading, 48) }
                            }
                        }
                        .cardStyle(padding: 4)
                    }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("工具")
    }

    @ViewBuilder
    private func destination(_ tool: Tool) -> some View {
        switch tool {
        case .continuousPing: MonitorView(mode: .continuousPing)
        case .dropMonitor: MonitorView(mode: .dropMonitor)
        case .serverBenchmark: ServerBenchmarkView()
        case .networkInfo: NetworkInfoView()
        default: ToolRunView(tool: tool)
        }
    }
}

private struct ToolRow: View {
    let tool: Tool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(tool.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
