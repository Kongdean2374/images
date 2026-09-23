import SwiftUI
import ChaiNetCore

/// Full result page (history, tools): summary → technical details → share / export.
struct ResultDetailView: View {
    let result: TestResult
    @Environment(SettingsStore.self) private var settings
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                ResultSummaryView(result: result)
                TechnicalDetailsView(result: result)
                shareCard
                RawDataCard(result: result)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(result.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: ResultExporter.shareSummary(result)) { Image(systemName: "square.and.arrow.up") }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.date(result.date)).font(.subheadline.weight(.semibold))
                Text("\(NetworkClass(snapshot: result.network).displayName) · \(result.server?.name ?? "—")")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if result.location != nil { Image(systemName: "location.fill").foregroundStyle(Theme.textSecondary) }
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("匯出").font(.headline)
            HStack {
                ForEach(ExportFormatSetting.allCases) { format in
                    Button(format == .json ? "JSON" : format == .csv ? "CSV" : "文字") {
                        exportURL = try? ExportService.exportResults([result], format: format,
                                                                     includeLocation: settings.settings.includeLocationInExports)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) { Label("分享 \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    .font(.footnote)
            }
            Text(settings.settings.includeLocationInExports ? "匯出包含位置資料。" : "匯出不含位置資料（可在設定中變更）。")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}
