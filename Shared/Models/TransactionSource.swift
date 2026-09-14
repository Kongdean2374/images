import Foundation

/// 一筆支出是從哪個管道進來的（計劃書 §資料模型 sourceType）。
enum TransactionSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case liveActivity
    case siri
    case ocrCamera
    case ocrPhotoLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "手動輸入"
        case .liveActivity: return "動態島"
        case .siri: return "Siri"
        case .ocrCamera: return "拍照辨識"
        case .ocrPhotoLibrary: return "相簿辨識"
        }
    }

    var iconName: String {
        switch self {
        case .manual: return "square.and.pencil"
        case .liveActivity: return "capsule.portrait"
        case .siri: return "mic.fill"
        case .ocrCamera: return "camera.fill"
        case .ocrPhotoLibrary: return "photo.on.rectangle"
        }
    }
}
