import Foundation
import SwiftData

/// 一鍵匯出 CSV（計劃書 §9）。輸出到暫存檔後交給系統分享面板。
enum CSVExporter {

    static let header = "日期,金額,分類,子分類,備註,情緒標籤,店名,來源"

    static func csvString(for expenses: [Expense]) -> String {
        var rows = [header]
        for expense in expenses.sorted(by: { $0.date < $1.date }) {
            let category = expense.category
            let parentName = category?.parent?.name ?? category?.name ?? ""
            let childName = category?.parent == nil ? "" : (category?.name ?? "")
            let fields = [
                DateHelper.csvDate(expense.date),
                String(format: "%.2f", expense.amount),
                parentName,
                childName,
                expense.note ?? "",
                expense.emotionTag?.name ?? "",
                expense.merchant ?? "",
                expense.source.displayName
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 寫出檔案，回傳可分享的 URL。加上 BOM 讓 Excel 開中文不亂碼。
    static func writeFile(expenses: [Expense], fileName: String? = nil) throws -> URL {
        let name = fileName ?? "MoneyLeft-\(DateHelper.csvDate(Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "")).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(csvString(for: expenses).utf8))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func allExpenses(in context: ModelContext) -> [Expense] {
        let descriptor = FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
