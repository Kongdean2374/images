import Foundation

enum WorkoutTime {
    static func pauses(start: Date, end: Date, log: [Date]) -> [DateInterval] {
        guard end >= start else { return [] }
        var result: [DateInterval] = []
        var index = 0
        while index < log.count {
            let a = max(start, log[index])
            let b = min(end, index + 1 < log.count ? log[index + 1] : end)
            if b > a { result.append(DateInterval(start: a, end: b)) }
            index += 2
        }
        return result
    }
}
