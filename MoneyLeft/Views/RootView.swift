import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var liveActivity: LiveActivityController

    @State private var selection: Tab = .home
    @State private var previousTab: Tab = .home
    @State private var showingEditor = false
    @State private var showingReceiptFlow = false
    @State private var showingQuickActions = false
    @State private var presetCategory: SpendingCategory?

    enum Tab: Hashable { case home, list, add, stats, settings }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == .add {
                    showingQuickActions = true          // 中間那顆不切頁，直接開記帳選單
                } else {
                    previousTab = selection
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            HomeView(selection: $selection, presetCategory: $presetCategory, showingEditor: $showingEditor)
                .tabItem { Label("首頁", systemImage: "house.fill") }
                .tag(Tab.home)

            ExpenseListView()
                .tabItem { Label("明細", systemImage: "list.bullet.rectangle.portrait.fill") }
                .tag(Tab.list)

            Color.clear
                .tabItem { Label("記一筆", systemImage: "plus.circle.fill") }
                .tag(Tab.add)

            StatsView()
                .tabItem { Label("報表", systemImage: "chart.bar.xaxis") }
                .tag(Tab.stats)

            MoreView()
                .tabItem { Label("更多", systemImage: "ellipsis.circle.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .onAppear {
            DefaultData.seedIfNeeded(context: context)
            BudgetService.refreshWidgetSnapshot(context: context)
        }
        .onOpenURL(perform: handle)
        .sheet(isPresented: $showingQuickActions) {
            QuickActionSheet(
                onManual: { presetCategory = nil; showingEditor = true },
                onScan: { showingReceiptFlow = true }
            )
            .presentationDetents([.height(430)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEditor, onDismiss: { presetCategory = nil }) {
            ExpenseEditorView(presetCategory: presetCategory)
        }
        .sheet(isPresented: $showingReceiptFlow) {
            ReceiptFlowView()
        }
    }

    /// moneyleft://add 、 moneyleft://scan 、 moneyleft://list
    private func handle(_ url: URL) {
        guard url.scheme == AppGroup.urlScheme else { return }
        switch url.host {
        case "add":
            selection = .home
            showingEditor = true
        case "scan":
            selection = .home
            showingReceiptFlow = true
        case "list":
            selection = .list
        case "stats":
            selection = .stats
        default:
            selection = .home
        }
    }
}

/// 中間「記一筆」按下去跳出來的選單：四種記帳方式一次擺齊
struct QuickActionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var liveActivity: LiveActivityController

    var onManual: () -> Void
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 6)

            Text("怎麼記這一筆？")
                .font(.headline)
                .padding(.bottom, 2)

            action(
                title: "手動輸入",
                subtitle: "金額、分類、情緒標籤",
                icon: "square.and.pencil",
                tint: Theme.accent
            ) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onManual() }
            }

            action(
                title: "收據辨識",
                subtitle: "拍照，或從相簿批次匯入",
                icon: "doc.text.viewfinder",
                tint: Color(hex: "#34C759")
            ) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onScan() }
            }

            action(
                title: liveActivity.isActive ? "關閉動態島記帳" : "開啟動態島記帳",
                subtitle: liveActivity.isActive ? "結束目前的記帳工作階段" : "在動態島上一鍵加金額、切分類",
                icon: "capsule.portrait",
                tint: Color(hex: "#BF5AF2")
            ) {
                if liveActivity.isActive {
                    liveActivity.end()
                } else {
                    liveActivity.start(context: context)
                }
                dismiss()
            }

            if let error = liveActivity.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func action(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
