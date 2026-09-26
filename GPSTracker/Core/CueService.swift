import Foundation
import AVFoundation
import UIKit

/// 語音與震動提示（間歇訓練、每公里播報）。
final class CueService: NSObject {
    static let shared = CueService()

    private let synthesizer = AVSpeechSynthesizer()
    private let settings = AppSettings.shared
    /// 音訊工作階段目前是不是我們啟用的
    private var sessionActive = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configureAudioSession() {
        guard !sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                            mode: .spokenAudio,
                                                            options: [.duckOthers, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            // 音訊不可用時靜默略過，不影響計時
        }
    }

    /// 播報結束就把工作階段關掉，否則使用者的音樂會一直被壓低音量。
    /// 以前只 setActive(true) 沒有關掉，播報過一次之後音樂就永遠小聲。
    private func releaseAudioSession() {
        guard sessionActive, !synthesizer.isSpeaking else { return }
        sessionActive = false
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false,
                                                           options: [.notifyOthersOnDeactivation])
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


extension CueService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        releaseAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        releaseAudioSession()
    }
}
