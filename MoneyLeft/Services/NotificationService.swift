import Foundation
import UserNotifications

/// 本地通知（完全在裝置上排程，不需要伺服器、不需要付費帳號）
enum NotificationService {

    static let dailyReminderID = "moneyleft.daily-reminder"

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return granted ?? false
    }

    /// 依設定重新排定每日提醒
    static func syncDailyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderID])
        guard AppSettings.dailyReminderEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "今天記帳了嗎？"
        content.body = "花 10 秒補一下，明天的額度才算得準。"
        content.sound = .default

        var components = DateComponents()
        components.hour = AppSettings.dailyReminderHour
        components.minute = AppSettings.dailyReminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: dailyReminderID, content: content, trigger: trigger))
    }

    /// 燒錢速度轉紅燈時提醒一次（同一天只提醒一次）
    static func scheduleOverspendAlertIfNeeded(summary: BudgetSummary) {
        guard AppSettings.overspendAlertEnabled,
              summary.monthlyBudget > 0,
              summary.burnLevel == .over else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let identifier = "moneyleft.overspend.\(formatter.string(from: Date()))"

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            guard !requests.contains(where: { $0.identifier == identifier }) else { return }

            let content = UNMutableNotificationContent()
            content.title = "花太快了"
            if let day = summary.projectedRunOutDay {
                content.body = "照目前速度，預算大約撐到 \(day) 號。每天剩 \(Money.string(summary.dailyAllowance)) 可用。"
            } else {
                content.body = "目前花費速度是理想值的 \(Int(summary.burnRatio * 100))%，留意一下。"
            }
            content.sound = .default

            var components = DateHelper.calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = 20
            components.minute = 0
            guard let fireDate = DateHelper.calendar.date(from: components), fireDate > Date() else { return }

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateHelper.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
