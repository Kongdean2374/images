import Foundation
import SwiftData
import UniformTypeIdentifiers

/// 完整備份／還原。沒有雲端，所以這是換手機、重灌時保住資料的唯一方法。
enum BackupService {

    static let fileExtension = "json"
    static let currentVersion = 1

    // MARK: - DTO

    struct Payload: Codable {
        var version: Int
        var exportedAt: Date
        var appVersion: String
        var monthlyBudget: Double
        var fixedExpenses: [FixedDTO]
        var categories: [CategoryDTO]
        var emotionTags: [TagDTO]
        var expenses: [ExpenseDTO]
        var phraseMappings: [PhraseDTO]
        var includesReceiptImages: Bool
    }

    struct FixedDTO: Codable {
        var name: String
        var amount: Double
        var dueDay: Int
    }

    struct CategoryDTO: Codable {
        var name: String
        var iconName: String
        var colorHex: String
        var isDefault: Bool
        var sortOrder: Int
        var parentName: String?
    }

    struct TagDTO: Codable {
        var name: String
        var iconName: String
        var colorHex: String
        var isBuiltIn: Bool
        var sortOrder: Int
    }

    struct ExpenseDTO: Codable {
        var amount: Double
        var date: Date
        var categoryName: String?
        var parentCategoryName: String?
        var note: String?
        var merchant: String?
        var emotionName: String?
        var source: String
        var receiptImageBase64: String?
    }

    struct PhraseDTO: Codable {
        var phrase: String
        var categoryName: String
        var hitCount: Int
    }

    // MARK: - 匯出

    static func makePayload(context: ModelContext, includeImages: Bool) -> Payload {
        let categories = (try? context.fetch(FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let tags = (try? context.fetch(FetchDescriptor<EmotionTag>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let phrases = (try? context.fetch(FetchDescriptor<PhraseMapping>())) ?? []
        let setting = (try? context.fetch(FetchDescriptor<BudgetSetting>()))?.first

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        return Payload(
            version: currentVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            monthlyBudget: setting?.monthlyBudget ?? 0,
            fixedExpenses: (setting?.sortedFixedExpenses ?? []).map {
                FixedDTO(name: $0.name, amount: $0.amount, dueDay: $0.dueDay)
            },
            categories: categories.map {
                CategoryDTO(
                    name: $0.name, iconName: $0.iconName, colorHex: $0.colorHex,
                    isDefault: $0.isDefault, sortOrder: $0.sortOrder, parentName: $0.parent?.name
                )
            },
            emotionTags: tags.map {
                TagDTO(name: $0.name, iconName: $0.iconName, colorHex: $0.colorHex,
                       isBuiltIn: $0.isBuiltIn, sortOrder: $0.sortOrder)
            },
            expenses: expenses.map { expense in
                ExpenseDTO(
                    amount: expense.amount,
                    date: expense.date,
                    categoryName: expense.category?.name,
                    parentCategoryName: expense.category?.parent?.name,
                    note: expense.note,
                    merchant: expense.merchant,
                    emotionName: expense.emotionTag?.name,
                    source: expense.sourceRaw,
                    receiptImageBase64: includeImages ? expense.receiptImageData?.base64EncodedString() : nil
                )
            },
            phraseMappings: phrases.map {
                PhraseDTO(phrase: $0.phrase, categoryName: $0.categoryName, hitCount: $0.hitCount)
            },
            includesReceiptImages: includeImages
        )
    }

    static func export(context: ModelContext, includeImages: Bool) throws -> URL {
        let payload = makePayload(context: context, includeImages: includeImages)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "MoneyLeft-backup-\(formatter.string(from: Date())).\(fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 還原

    struct RestoreSummary {
        var expenses: Int
        var categories: Int
        var exportedAt: Date
    }

    /// 整包取代目前資料。呼叫端必須先跟使用者確認過。
    static func restore(from url: URL, context: ModelContext) throws -> RestoreSummary {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)

        // 清空
        for expense in (try? context.fetch(FetchDescriptor<Expense>())) ?? [] { context.delete(expense) }
        for category in (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? [] { context.delete(category) }
        for tag in (try? context.fetch(FetchDescriptor<EmotionTag>())) ?? [] { context.delete(tag) }
        for phrase in (try? context.fetch(FetchDescriptor<PhraseMapping>())) ?? [] { context.delete(phrase) }
        for setting in (try? context.fetch(FetchDescriptor<BudgetSetting>())) ?? [] { context.delete(setting) }
        try? context.save()

        // 分類（先父後子）
        var categoryMap: [String: SpendingCategory] = [:]
        for dto in payload.categories where dto.parentName == nil {
            let category = SpendingCategory(
                name: dto.name, iconName: dto.iconName, colorHex: dto.colorHex,
                isDefault: dto.isDefault, sortOrder: dto.sortOrder
            )
            context.insert(category)
            categoryMap[dto.name] = category
        }
        for dto in payload.categories where dto.parentName != nil {
            let parent = dto.parentName.flatMap { categoryMap[$0] }
            let category = SpendingCategory(
                name: dto.name, iconName: dto.iconName, colorHex: dto.colorHex,
                isDefault: dto.isDefault, sortOrder: dto.sortOrder, parent: parent
            )
            context.insert(category)
            categoryMap[(dto.parentName ?? "") + "/" + dto.name] = category
        }

        var tagMap: [String: EmotionTag] = [:]
        for dto in payload.emotionTags {
            let tag = EmotionTag(
                name: dto.name, iconName: dto.iconName, colorHex: dto.colorHex,
                isBuiltIn: dto.isBuiltIn, sortOrder: dto.sortOrder
            )
            context.insert(tag)
            tagMap[dto.name] = tag
        }

        let setting = BudgetSetting(monthlyBudget: payload.monthlyBudget)
        context.insert(setting)
        for dto in payload.fixedExpenses {
            let fixed = FixedExpense(name: dto.name, amount: dto.amount, dueDay: dto.dueDay)
            fixed.budget = setting
            context.insert(fixed)
        }

        for dto in payload.expenses {
            var category: SpendingCategory?
            if let parentName = dto.parentCategoryName, let name = dto.categoryName {
                category = categoryMap[parentName + "/" + name]
            } else if let name = dto.categoryName {
                category = categoryMap[name]
            }
            let expense = Expense(
                amount: dto.amount,
                date: dto.date,
                category: category,
                note: dto.note,
                emotionTag: dto.emotionName.flatMap { tagMap[$0] },
                source: TransactionSource(rawValue: dto.source) ?? .manual,
                merchant: dto.merchant,
                receiptImageData: dto.receiptImageBase64.flatMap { Data(base64Encoded: $0) }
            )
            context.insert(expense)
        }

        for dto in payload.phraseMappings {
            let mapping = PhraseMapping(phrase: dto.phrase, categoryName: dto.categoryName)
            mapping.hitCount = dto.hitCount
            context.insert(mapping)
        }

        try context.save()
        return RestoreSummary(
            expenses: payload.expenses.count,
            categories: payload.categories.count,
            exportedAt: payload.exportedAt
        )
    }
}
