import Foundation

/// 一段「沒有軌跡但仍在記錄」的區間。
///
/// GPS 失效或精度太差時，App 會自動改用計步推估距離。那段期間不寫入
/// 任何座標點，所以地圖上會是一段空白；但時間、距離、步數都持續累積，
/// 回放時再依時間等速通過這段空白，銜接到定位恢復的那一點。
struct CoverageGap: Codable, Hashable, Identifiable {
    var id: Date { start }

    var start: Date
    var end: Date
    /// 進入空白段時的累積距離（公尺）
    var startDistance: Double
    /// 離開空白段時的累積距離（公尺）
    var endDistance: Double
    /// 這段期間走了幾步（有計步資料才有值）
    var steps: Int?
    /// 距離是怎麼補起來的
    var sourceRaw: String

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var distance: Double { max(0, endDistance - startDistance) }
    var source: DistanceSource { DistanceSource(rawValue: sourceRaw) ?? .stride }

    /// 這段的推估平均速度（公尺/秒）
    var averageSpeed: Double? {
        guard duration > 1, distance > 0 else { return nil }
        return distance / duration
    }

    enum Reason: String, Codable {
        /// 完全收不到座標
        case noSignal
        /// 有座標但誤差太大
        case poorAccuracy

        var displayName: String {
            switch self {
            case .noSignal: return "沒有定位訊號"
            case .poorAccuracy: return "定位精度太差"
            }
        }
    }

    var reasonRaw: String
    var reason: Reason { Reason(rawValue: reasonRaw) ?? .noSignal }
}

extension Array where Element == CoverageGap {
    /// 編碼成字串存進 SwiftData（避免自訂型別陣列的相容性問題）
    var encodedJSON: String? {
        guard !isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [CoverageGap] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CoverageGap].self, from: data)) ?? []
    }
}
