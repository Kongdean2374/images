import Foundation
import CoreMotion

/// 每日活動看板：即使 App 沒開，系統也保留了計步資料（約 7 天），
/// 這裡把它回溯查出來畫成圖表。完全不需要定位。
final class DailyActivityProvider: ObservableObject {

    struct DayStat: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let steps: Int
        let distance: Double?
        let floors: Int

        var isToday: Bool { Calendar.current.isDateInToday(date) }
        var weekdayLabel: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_TW")
            f.dateFormat = "E"
            return f.string(from: date)
        }
    }

    @Published private(set) var days: [DayStat] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isAvailable = CMPedometer.isStepCountingAvailable()

    var todaySteps: Int { days.last(where: { $0.isToday })?.steps ?? 0 }
    var todayFloors: Int { days.last(where: { $0.isToday })?.floors ?? 0 }
    var todayDistance: Double? { days.last(where: { $0.isToday })?.distance }
    var weekSteps: Int { days.reduce(0) { $0 + $1.steps } }
    var bestDay: DayStat? { days.max { $0.steps < $1.steps } }

    // MARK: 空資料判斷（完全沒有資料的項目直接在 UI 隱藏，不要顯示 0 或 --）

    /// 這段期間完全沒有任何步數資料
    var hasAnyData: Bool { days.contains { $0.steps > 0 } }
    /// 今天有沒有步數
    var hasTodayData: Bool { todaySteps > 0 }
    /// 有沒有任何一天量到步行距離
    var hasDistanceData: Bool { days.contains { ($0.distance ?? 0) > 0 } }
    /// 有沒有任何一天量到爬樓層
    var hasFloorData: Bool { days.contains { $0.floors > 0 } }

    @MainActor
    func load(dayCount: Int = 7) async {
        guard CMPedometer.isStepCountingAvailable() else {
            isAvailable = false
            return
        }
        isAvailable = true
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [DayStat] = []

        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let end = min(Date(), calendar.date(byAdding: .day, value: 1, to: start) ?? Date())
            guard end > start else { continue }
            let data = await PedometerManager.query(from: start, to: end)
            result.append(DayStat(date: start,
                                  steps: data?.numberOfSteps.intValue ?? 0,
                                  distance: data?.distance?.doubleValue,
                                  floors: data?.floorsAscended?.intValue ?? 0))
        }
        days = result
    }
}
