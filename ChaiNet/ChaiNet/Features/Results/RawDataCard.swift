import SwiftUI
import UIKit
import ChaiNetCore

/// "完整原始資料" — the complete English export (every sample, every statistic, root-cause codes)
/// for engineers and AI assistants. Copy, or share as TXT / JSON.
struct RawDataCard: View {
    let result: TestResult
    @Environment(AppContainer.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var text: String?
    @State private var txtURL: URL?
    @State private var jsonURL: URL?
    @State private var copied = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("完整原始資料（工程師 / AI 分析用）", systemImage: "doc.plaintext").font(.headline)
            Text("英文 + 數字格式，保留每一筆 100 ms 速度樣本、每個延遲探測、所有統計、端點、路由、根因分析代碼。可直接貼給 ChatGPT、Claude 或工程師。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let text {
                HStack {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: { Label(copied ? "已複製" : "複製全部", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderedProminent)
                    if let txtURL { ShareLink(item: txtURL) { Label("TXT", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered) }
                    if let jsonURL { ShareLink(item: jsonURL) { Label("JSON", systemImage: "curlybraces") }.buttonStyle(.bordered) }
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                Text("\(lines.count) 行 · \(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                Text(showAll ? text : lines.prefix(40).joined(separator: "\n") + "\n…")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                Button(showAll ? "收合預覽" : "顯示全部預覽") { showAll.toggle() }.font(.caption)
            } else {
                ProgressView("產生中…")
            }
        }
        .cardStyle()
        .task(id: result.id) { await build() }
    }

    private func build() async {
        let r = result
        let includeLocation = settings.settings.includeLocationInExports
        let baselines = app.baselines(excluding: [r.id])
        let analysis = RawDataExporter.analysis(for: r, baselines: baselines)
        text = RawDataExporter.text(r, analysis: analysis, appVersion: ExportService.appVersion, platform: ExportService.platform,
                                    includeLocation: includeLocation)
        txtURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: false, includeLocation: includeLocation)
        jsonURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: true, includeLocation: includeLocation)
    }
}
