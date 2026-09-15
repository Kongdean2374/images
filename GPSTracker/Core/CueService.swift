import Foundation
import AVFoundation
import UIKit

/// 語音與震動提示（間歇訓練、每公里播報）。
@MainActor
final class CueService {
    static let shared = CueService()

    private let synthesizer = AVSpeechSynthesizer()
    private let settings = AppSettings.shared

    private init() {}

    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                            mode: .spokenAudio,
                                                            options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 音訊不可用時靜默略過，不影響計時
        }
    }

    func speak(_ text: String) {
        guard settings.voiceCues else { return }
        configureAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard settings.hapticCues else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard settings.hapticCues else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
