import SwiftUI
import UIKit
import ChaiNetCore

/// Technical report: plain text for pasting into an AI assistant / support ticket, and JSON with
/// every raw sample for re-analysis.
struct DiagnosticReportView: View {
    let report: DiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var textURL: URL?
    @State private var jsonURL: URL?

    private var text: String { DiagnosticReportGenerator().text(report) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: { Label(copied ? "已複製" : "複製文字報告", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderedProminent)
                    if let textURL { ShareLink(item: textURL) { Label("TXT", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered) }
                    if let jsonURL { ShareLink(item: jsonURL) { Label("JSON", systemImage: "curlybraces") }.buttonStyle(.bordered) }
                }
                Text("文字報告可直接貼給 ChatGPT、Claude 或工程師；JSON 保留全部原始資料與診斷結果。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 12)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("ChaiNet Diagnostic Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
        .task {
            textURL = try? ExportService.exportReport(report, asJSON: false)
            jsonURL = try? ExportService.exportReport(report, asJSON: true)
        }
    }
}
