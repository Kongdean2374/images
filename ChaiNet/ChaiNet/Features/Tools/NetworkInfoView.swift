import SwiftUI
import ChaiNetCore

struct NetworkInfoView: View {
    @Environment(AppContainer.self) private var app
    @State private var snapshot: NetworkSnapshot?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NetworkStatusCard(snapshot: snapshot ?? app.currentNetwork)
                if let snapshot {
                    VStack(alignment: .leading, spacing: 8) {
                        NetworkEnvironmentDetail(n: snapshot)
                    }
                    .cardStyle()
                    Text("標示「無法取得」的項目是 iOS 不開放給 App 的資訊，ChaiNet 不會以模擬值代替。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    ProgressView().padding()
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("網路介面資訊")
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        snapshot = await app.networkInfo.snapshot(includePublicIP: true)
        loading = false
    }
}
