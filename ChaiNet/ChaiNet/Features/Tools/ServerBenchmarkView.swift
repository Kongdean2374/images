import SwiftUI
import ChaiNetCore

/// Latency to every configured server; tap one to use it for tests.
struct ServerBenchmarkView: View {
    @Environment(AppContainer.self) private var app
    @State private var rankings: [ServerLatencyRanking] = []
    @State private var running = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    HStack {
                        Label(running ? "測試中…" : "測試所有伺服器", systemImage: "play.fill")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running)
            } footer: {
                Text("每個伺服器以 HTTP 量測 3 次延遲並取中位數。可在「設定 › 伺服器」加入自架 ChaiNet 伺服器。")
            }
            if !rankings.isEmpty {
                Section("結果") {
                    ForEach(rankings) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.server.name)
                                Text(r.server.location).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Text(r.error ?? Format.ms(r.medianMs, digits: 1)).monospacedDigit()
                                .foregroundStyle(r.error == nil ? Theme.textPrimary : Theme.critical)
                            Button("使用") {
                                app.settings.settings.serverSelection = .manual
                                app.settings.settings.manualServerID = r.server.id
                            }
                            .buttonStyle(.bordered)
                            .disabled(r.medianMs == nil)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("伺服器基準")
        .onDisappear { task?.cancel() }
    }

    private func run() {
        running = true
        let servers = app.settings.allServers
        let directory = app.serverDirectory
        task = Task {
            let result = await directory.rank(servers)
            rankings = result
            running = false
        }
    }
}
