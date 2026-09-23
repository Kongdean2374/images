import SwiftUI

/// 診斷紀錄：非正常結束與關鍵事件都會留下技術細節，方便回報問題。
struct DiagnosticsView: View {
    @State private var entries: [DiagnosticsLog.Entry] = []
    @State private var exportURL: URL?
    @State private var showClearConfirm = false
    @State private var copied = false

    private var abnormalCount: Int {
        entries.filter { $0.level == .error }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                environmentCard
                actionsCard
                if entries.isEmpty {
                    EmptyStateView(systemImage: "checkmark.seal",
                                   title: "目前沒有異常紀錄",
                                   message: "運動被系統中斷時，這裡會留下當下的狀態與推測原因。",
                                   compact: true)
                } else {
                    ForEach(entries.reversed()) { entry in
                        entryCard(entry)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("診斷紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = DiagnosticsLog.shared.entries }
        .confirmationDialog("清除所有診斷紀錄？",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                DiagnosticsLog.shared.clear()
                entries = []
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var summaryCard: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((abnormalCount > 0 ? Theme.accentWarm : Theme.mint).opacity(0.18))
                    Image(systemName: abnormalCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(abnormalCount > 0 ? Theme.accentWarm : Theme.mint)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(abnormalCount > 0 ? "偵測到 \(abnormalCount) 次異常中斷" : "沒有異常中斷")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("共 \(entries.count) 筆事件")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var environmentCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("目前環境", systemImage: "iphone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(DiagnosticsLog.environmentDetail.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                    HStack {
                        Text(item.key)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(item.value)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = DiagnosticsLog.shared.exportText()
                copied = true
                CueService.shared.notify(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
            } label: {
                Label(copied ? "已複製到剪貼簿" : "複製完整報告", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(PrimaryButtonStyle())

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享報告檔案", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    exportURL = DiagnosticsLog.shared.exportFile()
                } label: {
                    Label("產生報告檔案", systemImage: "doc.text")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Text("清除紀錄")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentWarm)
            }
        }
    }

    private func entryCard(_ entry: DiagnosticsLog.Entry) -> some View {
        GlassCard(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: entry.level.icon)
                        .font(.caption)
                        .foregroundStyle(color(for: entry.level))
                    Text(entry.message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(entry.category)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(Theme.textSecondary)
                    Text(DiagnosticsLog.timestamp(entry.date))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                if !entry.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(entry.detail.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                            HStack(alignment: .top) {
                                Text(item.key)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer(minLength: 8)
                                Text(item.value)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
                }
            }
        }
    }

    private func color(for level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .info: return Theme.textSecondary
        case .warning: return Theme.amber
        case .error: return Theme.accentWarm
        }
    }
}
