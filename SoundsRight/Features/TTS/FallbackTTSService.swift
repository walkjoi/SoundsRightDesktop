import Foundation
import AVFoundation

/// Last-resort TTS that speaks through `AVSpeechSynthesizer` directly (no audio data produced).
///
/// `@MainActor` class rather than an actor because it must conform to
/// `AVSpeechSynthesizerDelegate` (an NSObjectProtocol-based, Sendable protocol);
/// global-actor isolation gives the same compiler-enforced synchronization.
///
/// Every utterance carries a generation token so callers can attribute finish/cancel
/// events (and stop requests) to a specific utterance — a plain "is speaking" flag
/// cannot distinguish a late event for utterance N from the live utterance N+1.
@MainActor
final class FallbackTTSService: NSObject, AVSpeechSynthesizerDelegate {
    /// Invoked when an utterance ends with its generation and whether it finished
    /// naturally (`true`) or was cancelled (`false`).
    private var onFinished: ((Int, Bool) -> Void)?

    private var currentGeneration = 0
    private var utteranceGenerations: [ObjectIdentifier: Int] = [:]

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    nonisolated override init() {
        super.init()
    }

    func setOnFinished(_ handler: @escaping @MainActor @Sendable (Int, Bool) -> Void) {
        onFinished = handler
    }

    /// Starts speaking and returns the new utterance's generation immediately,
    /// or nil if speech could not be started. Any in-progress utterance is cancelled first.
    func startSpeaking(text: String, rate: PlaybackRate) -> Int? {
        guard !text.isEmpty else { return nil }

        stop()

        currentGeneration += 1
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = mapRateToAVSpeech(rate)
        utteranceGenerations[ObjectIdentifier(utterance)] = currentGeneration
        synthesizer.speak(utterance)
        return currentGeneration
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Stops speech only if the live utterance still belongs to `generation` —
    /// lets a superseded caller clean up its own orphan without killing a newer utterance.
    func stop(ifGeneration generation: Int) {
        guard generation == currentGeneration else { return }
        stop()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        // ObjectIdentifier is Sendable; the utterance itself must not cross actors.
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finishUtterance(key: key, finishedNaturally: true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finishUtterance(key: key, finishedNaturally: false)
        }
    }

    private func finishUtterance(key: ObjectIdentifier, finishedNaturally: Bool) {
        guard let generation = utteranceGenerations.removeValue(forKey: key) else {
            return
        }
        onFinished?(generation, finishedNaturally)
    }

    // MARK: - Rate Mapping

    /// Maps the app's playback rate onto AVSpeech's 0...1 scale (0.5 is normal speed).
    /// Exhaustive over `PlaybackRate` so adding a case forces an update here.
    private func mapRateToAVSpeech(_ rate: PlaybackRate) -> Float {
        switch rate {
        case .slow:
            return 0.35
        case .moderate:
            return 0.42
        case .normal:
            return 0.5
        case .fast:
            return 0.57
        case .faster:
            return 0.64
        }
    }
}
