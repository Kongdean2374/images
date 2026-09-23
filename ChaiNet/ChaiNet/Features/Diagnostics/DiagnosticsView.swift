import SwiftUI
import ChaiNetCore

struct DiagnosticsView: View {
    @Environment(AppContainer.self) private var app
    @State private var sessions: [DiagnosticSession] = []
    @State private var newSession: DiagnosticSession?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                intro
                NavigationLink { TroubleshootingWizardView() } label: {
                    actionRow(symbol: "wand.and.stars", title: "疑難排解精靈", subtitle: "選擇遇到的問題，只執行必要的測試")
                }
                .buttonStyle(.plain)
                Button {
                    newSession = DiagnosticSession(title: "完整診斷 \(Format.date(Date()))")
                } label: {
                    actionRow(symbol: "stethoscope", title: "完整診斷工作階段", subtitle: "執行所有項目，並可加入 LTE / 5G / Wi-Fi / IPv4 / IPv6 測試")
                }
                .buttonStyle(.plain)

                if !sessions.isEmpty {
                    SectionTitle(title: "診斷紀錄")
                    ForEach(sessions) { s in
                        NavigationLink { DiagnosticSessionView(session: s, autoRun: nil) } label: { SessionRow(session: s) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("刪除", role: .destructive) {
                                    try? app.history.deleteSession(id: s.id)
                                }
                            }
                    }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("診斷")
        .navigationDestination(item: $newSession) { s in
            DiagnosticSessionView(session: s, autoRun: TestProfile.fullDiagnostics.items)
        }
        .task(id: app.history.changeToken) { sessions = app.history.sessions() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Root Cause Diagnostics", systemImage: "scope").font(.headline).foregroundStyle(Theme.accent)
            Text("以證據為基礎的鑑別診斷：交叉比較多個伺服器、IPv4 / IPv6、Wi-Fi / LTE / 5G 與歷史基準，找出問題最可能位於哪一層，並列出可排除的原因與下一步驗證測試。")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }

    private func actionRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}

private struct SessionRow: View {
    let session: DiagnosticSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text("\(session.tests.count) 項測試 · \(Format.relative(session.createdAt))").font(.caption).foregroundStyle(Theme.textSecondary)
            if let symptom = session.symptom { Badge(text: symptom.displayName, color: Theme.info) }
        }
        .cardStyle(padding: 12)
    }
}

