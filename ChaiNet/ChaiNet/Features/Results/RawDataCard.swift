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
    /// AI-safe (IPs redacted) is the default; the engineer export can opt in to full IPs.
    @State private var engineer = false
    @State private var includeIPs = false
    private var privacy: ExportPrivacy { engineer ? .engineer(includeIPs: includeIPs) : .aiSafe }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("完整原始資料（工程師 / AI 分析用）", systemImage: "doc.plaintext").font(.headline)
            Text("英文 + 數字格式，保留每一筆 100 ms 速度樣本、每個延遲探測、所有統計、端點、路由、根因分析代碼。可直接貼給 ChatGPT、Claude 或工程師。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Picker("匯出類型", selection: $engineer) {
                Text("匯出 AI 分析").tag(false)
                Text("Raw Engineer Data").tag(true)
            }
            .pickerStyle(.segmented)
            if engineer {
                Toggle("包含完整 IP 位址", isOn: $includeIPs).font(.footnote)
            }
            Text(privacy.redactsIPs
                 ? "公網 / 區網 / VPN 通道 IPv4 與 IPv6 位址已遮蔽為 [REDACTED]（1.1.1.1、8.8.8.8 等公共服務位址保留）。"
                 : "包含完整 IP 位址，分享前請確認對象可信。")
                .font(.caption2).foregroundStyle(privacy.redactsIPs ? Theme.textSecondary : Color.orange)
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
        .task(id: "\(result.id)-\(engineer)-\(includeIPs)") { await build() }
    }

    private func build() async {
        let r = result
        let includeLocation = settings.settings.includeLocationInExports
        let baselines = app.baselines(excluding: [r.id])
        let analysis = RawDataExporter.analysis(for: r, baselines: baselines)
        let privacy = privacy
        copied = false
        text = RawDataExporter.text(r, analysis: analysis, appVersion: ExportService.appVersion, platform: ExportService.platform,
                                    includeLocation: includeLocation, privacy: privacy)
        txtURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: false, includeLocation: includeLocation, privacy: privacy)
        jsonURL = try? ExportService.exportRawData(r, analysis: analysis, asJSON: true, includeLocation: includeLocation, privacy: privacy)
    }
}
