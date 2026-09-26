import Foundation
import UserNotifications

/// 本地通知（不需網路、不需帳號）。
enum NotificationManager {

    enum Identifier {
        static let dailySteps = "dailyStepsReminder"
        static let streak = "streakReminder"
        static let sedentary = "sedentaryReminder"
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 每日步數提醒（固定時間提醒今天還沒達標）
    static func scheduleDailyStepReminder(hour: Int, minute: Int = 0, goal: Int) {
        let content = UNMutableNotificationContent()
        content.title = "今天的步數目標"
        content.body = "目標 \(goal) 步，打開 App 看看還差多少。"
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: Identifier.dailySteps, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// 連續運動天數即將中斷的提醒
    static func scheduleStreakReminder(hour: Int = 20, streak: Int) {
        guard streak > 0 else {
            cancel(Identifier.streak)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "連續 \(streak) 天了"
        content.body = "今天還沒有運動紀錄，動一下就能延續連續天數。"
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: Identifier.streak, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// 久坐提醒（每 N 小時一次）
    static func scheduleSedentaryReminder(intervalHours: Int) {
        cancel(Identifier.sedentary)
        guard intervalHours > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "起來動一動"
        content.body = "已經坐了一段時間了，走個幾分鐘吧。"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(intervalHours * 3600),
                                                        repeats: true)
        let request = UNNotificationRequest(identifier: Identifier.sedentary, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel(_ identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
