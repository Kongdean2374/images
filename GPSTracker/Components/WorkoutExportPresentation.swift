import SwiftUI
import UIKit

struct WorkoutExportFile: Identifiable {
    let id = UUID()
    let url: URL
}
@MainActor
final class WorkoutExportCoordinator: ObservableObject {
    @Published var file: WorkoutExportFile?
    @Published var error: String?
    @Published private(set) var isPreparing = false
    func exportSession(id: UUID, format: WorkoutExportFormat) {
        guard !isPreparing, file == nil else { return }
        guard let writer = WorkoutExportRepository.writer else { error = "匯出資料庫尚未就緒"; return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do { present(try await writer.sessionFile(id: id, format: format)) }
            catch { self.error = "無法讀取運動檔案：" + error.localizedDescription }
        }
    }
    func exportHistory() {
        guard !isPreparing, file == nil else { return }
        guard let writer = WorkoutExportRepository.writer else { error = "匯出資料庫尚未就緒"; return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do { present(try await writer.historyCSV()) }
            catch { self.error = "無法讀取運動紀錄：" + error.localizedDescription }
        }
    }
    func present(_ url: URL?) {
        guard file == nil else { return }
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            error = DataExporter.lastWriteError ?? "沒有可分享的資料，或檔案建立失敗。請確認剩餘儲存空間後重試。"
            return
        }
        file = WorkoutExportFile(url: url)
    }
}
private struct WorkoutFileActivity: UIViewControllerRepresentable {
    let file: WorkoutExportFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct WorkoutExportModifier: ViewModifier {
    @ObservedObject var coordinator: WorkoutExportCoordinator
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if coordinator.isPreparing { ProgressView("正在建立匯出檔案…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
        }.sheet(item: $coordinator.file) { file in WorkoutFileActivity(file: file) }
            .alert("匯出失敗", isPresented: Binding(get: { coordinator.error != nil }, set: { if !$0 { coordinator.error = nil } })) {
                Button("好") { coordinator.error = nil }
            } message: { Text(coordinator.error ?? "") }
    }
}
extension View {
    func workoutExport(using coordinator: WorkoutExportCoordinator) -> some View { modifier(WorkoutExportModifier(coordinator: coordinator)) }
}
