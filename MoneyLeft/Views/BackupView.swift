import SwiftUI
import SwiftData

/// 備份與還原。沒有雲端同步，所以這頁就是你的保險。
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Query private var expenses: [Expense]

    @State private var includeImages = false
    @State private var exportFile: ExportFile?
    @State private var showingPicker = false
    @State private var pendingRestoreURL: URL?
    @State private var showingRestoreConfirm = false
    @State private var resultMessage: String?
    @State private var showingResult = false
    @State private var isWorking = false

    private var receiptCount: Int {
        expenses.filter { $0.receiptImageData != nil }.count
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $includeImages) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("包含收據照片")
                        Text("\(receiptCount) 張，檔案會大很多")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(receiptCount == 0)

                Button {
                    export()
                } label: {
                    Label("匯出備份檔", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)
            } header: {
                Text("備份")
            } footer: {
                Text("會把預算、固定支出、分類（含子分類）、情緒標籤、所有紀錄、個人語音詞庫全部寫成一個檔案。存到「檔案」App、AirDrop 給自己或傳到電腦都可以。")
            }

            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("從備份檔還原", systemImage: "square.and.arrow.down")
                }
                .disabled(isWorking)
            } header: {
                Text("還原")
            } footer: {
                Text("⚠️ 還原會「完全取代」目前這台裝置上的所有資料。建議先匯出一份現況備份再還原。")
            }

            Section("目前資料") {
                LabeledContent("紀錄", value: "\(expenses.count) 筆")
                LabeledContent("收據照片", value: "\(receiptCount) 張")
            }
        }
        .navigationTitle("備份與還原")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { ActivityView(items: [$0.url]) }
        .sheet(isPresented: $showingPicker) {
            DocumentPicker { url in
                pendingRestoreURL = url
                showingRestoreConfirm = true
            }
        }
        .alert("確定要還原？", isPresented: $showingRestoreConfirm) {
            Button("取代全部資料", role: .destructive) { restore() }
            Button("取消", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("目前裝置上的所有紀錄會被備份檔的內容取代，這個動作無法復原。")
        }
        .alert("備份", isPresented: $showingResult) {
            Button("好") {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func export() {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try BackupService.export(context: context, includeImages: includeImages)
            exportFile = ExportFile(url: url)
        } catch {
            resultMessage = "匯出失敗：\(error.localizedDescription)"
            showingResult = true
        }
    }

    private func restore() {
        guard let url = pendingRestoreURL else { return }
        isWorking = true
        defer { isWorking = false; pendingRestoreURL = nil }
        do {
            let summary = try BackupService.restore(from: url, context: context)
            BudgetService.refreshWidgetSnapshot(context: context)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_Hant_TW")
            formatter.dateFormat = "yyyy/M/d HH:mm"
            resultMessage = "已還原 \(summary.expenses) 筆紀錄、\(summary.categories) 個分類。\n備份時間：\(formatter.string(from: summary.exportedAt))"
        } catch {
            resultMessage = "還原失敗，檔案可能不是 MoneyLeft 的備份或已損壞。\n\(error.localizedDescription)"
        }
        showingResult = true
    }
}
