import Foundation
import SwiftData

/// 第一次啟動時建立預設分類、子分類與情緒標籤。
enum DefaultData {

    struct CategorySeed {
        let name: String
        let icon: String
        let color: String
        let children: [String]
    }

    static let categories: [CategorySeed] = [
        .init(name: "餐飲", icon: "fork.knife", color: "#FF6B6B", children: ["早餐", "午餐", "晚餐", "飲料", "宵夜"]),
        .init(name: "交通", icon: "tram.fill", color: "#32ADE6", children: ["大眾運輸", "加油", "計程車"]),
        .init(name: "日用品", icon: "cart.fill", color: "#34C759", children: ["生活雜貨", "清潔用品"]),
        .init(name: "娛樂", icon: "gamecontroller.fill", color: "#BF5AF2", children: ["訂閱服務", "遊戲", "出遊"]),
        .init(name: "治裝", icon: "tshirt.fill", color: "#FF9F0A", children: []),
        .init(name: "醫療", icon: "cross.case.fill", color: "#FF375F", children: ["門診", "藥品"]),
        .init(name: "通訊", icon: "antenna.radiowaves.left.and.right", color: "#5E5CE6", children: []),
        .init(name: "其他", icon: "ellipsis.circle.fill", color: "#8E8E93", children: [])
    ]

    @discardableResult
    static func seedIfNeeded(context: ModelContext) -> Bool {
        let categoryCount = (try? context.fetchCount(FetchDescriptor<SpendingCategory>())) ?? 0
        let tagCount = (try? context.fetchCount(FetchDescriptor<EmotionTag>())) ?? 0
        var didSeed = false

        if categoryCount == 0 {
            for (index, seed) in categories.enumerated() {
                let parent = SpendingCategory(
                    name: seed.name,
                    iconName: seed.icon,
                    colorHex: seed.color,
                    isDefault: true,
                    sortOrder: index
                )
                context.insert(parent)
                for (childIndex, childName) in seed.children.enumerated() {
                    let child = SpendingCategory(
                        name: childName,
                        iconName: seed.icon,
                        colorHex: seed.color,
                        isDefault: true,
                        sortOrder: childIndex,
                        parent: parent
                    )
                    context.insert(child)
                }
            }
            didSeed = true
        }

        if tagCount == 0 {
            for (index, tag) in EmotionTag.builtIns.enumerated() {
                context.insert(EmotionTag(
                    name: tag.name,
                    iconName: tag.icon,
                    colorHex: tag.color,
                    isBuiltIn: true,
                    sortOrder: index
                ))
            }
            didSeed = true
        }

        if didSeed {
            try? context.save()
            AppSettings.didSeedDefaults = true
        }
        return didSeed
    }

    /// Live Activity / Siri 沒有指定分類時的落點。
    static func fallbackCategory(context: ModelContext) -> SpendingCategory? {
        let descriptor = FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.name == "其他" } ?? all.first
    }

    static func category(named name: String, context: ModelContext) -> SpendingCategory? {
        let descriptor = FetchDescriptor<SpendingCategory>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.name == name }
    }
}
