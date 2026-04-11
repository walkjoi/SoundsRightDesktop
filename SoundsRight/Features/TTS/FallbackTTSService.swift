import Foundation
import AVFoundation

class FallbackTTSService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(text: String, rate: Float) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = mapRateToAVSpeech(rate)

        synthesizer.speak(utterance)
    }

    func speakAsync(text: String, rate: Float) async {
        await withCheckedContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = mapRateToAVSpeech(rate)

            self.completion = {
                continuation.resume()
            }

            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        completion?()
        completion = nil
    }

    private func mapRateToAVSpeech(_ rate: Float) -> Float {
        switch rate {
        case 0.5:
            return 0.35
        case 0.75:
            return 0.42
        case 1.0:
            return 0.5
        case 1.25:
            return 0.57
        default:
            return 0.5
        }
    }
}
