import Foundation

/// 運動中的語音播報：間隔與內容都可以自訂。
final class AnnouncementService {
    private var lastDistanceMark: Double = 0
    private var lastTimeMark: TimeInterval = 0

    func reset() {
        lastDistanceMark = 0
        lastTimeMark = 0
    }

    /// 依設定判斷此刻是否該播報，並組出內容
    func announceIfNeeded(distance: Double,
                          elapsed: TimeInterval,
                          averagePace: Double?,
                          currentPace: Double?,
                          pacerDelta: TimeInterval?) {
        let settings = AppSettings.shared
        let interval = settings.announceIntervalRaw
        guard interval != 0, settings.voiceCues else { return }

        if interval > 0 {
            guard distance - lastDistanceMark >= interval else { return }
            lastDistanceMark = floor(distance / interval) * interval
        } else {
            let minutes = -interval * 60
            guard elapsed - lastTimeMark >= minutes else { return }
            lastTimeMark = floor(elapsed / minutes) * minutes
        }

        var parts: [String] = []
        if settings.announceDistance {
            parts.append(distancePhrase(distance, unit: settings.unit))
        }
        if settings.announceDuration {
            parts.append("用時 \(durationPhrase(elapsed))")
        }
        if settings.announcePace, let pace = averagePace ?? currentPace {
            parts.append("平均配速 \(pacePhrase(pace, unit: settings.unit))")
        }
        if settings.announcePacerDelta, let delta = pacerDelta {
            parts.append(delta >= 0
                         ? "領先目標 \(Int(abs(delta))) 秒"
                         : "落後目標 \(Int(abs(delta))) 秒")
        }
        guard !parts.isEmpty else { return }

        CueService.shared.impact(.medium)
        CueService.shared.speak(parts.joined(separator: "，"))
    }

    private func distancePhrase(_ meters: Double, unit: DistanceUnit) -> String {
        if unit == .metric {
            let km = meters / 1000
            if km >= 1 {
                return km == km.rounded() ? "已完成 \(Int(km)) 公里" : String(format: "已完成 %.2f 公里", km)
            }
            return "已完成 \(Int(meters)) 公尺"
        }
        return String(format: "已完成 %.2f 英里", meters / 1609.344)
    }

    private func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let remainder = total % 60
        if minutes > 0 {
            return remainder > 0 ? "\(minutes) 分 \(remainder) 秒" : "\(minutes) 分"
        }
        return "\(remainder) 秒"
    }

    private func pacePhrase(_ pace: Double, unit: DistanceUnit) -> String {
        let converted = unit == .metric ? pace : pace * 1.609344
        let minutes = Int(converted) / 60
        let seconds = Int(converted) % 60
        return "\(minutes) 分 \(seconds) 秒"
    }
}
