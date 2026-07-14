import Foundation
import os

actor TTSManager {
    private let edgeTTS = EdgeTTSService()
    private let fallbackTTS = FallbackTTSService()
    private let cache = AudioCache()
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "TTSManager")

    enum TTSResult {
        case audioData(Data)
        /// Fallback speech has *started*; the payload is the utterance generation.
        /// Completion arrives via the handler passed to `setFallbackFinishedHandler`.
        case fallbackUsed(Int)
        case failed(Error)
    }

    /// Bumped per synthesize call so a superseded call can detect it was overtaken
    /// (the actor is reentrant at every await).
    private var synthesisGeneration = 0

    /// Registers the callback invoked when a fallback utterance ends, with the
    /// utterance generation and whether it finished naturally (vs. cancelled).
    func setFallbackFinishedHandler(_ handler: @escaping @MainActor @Sendable (Int, Bool) -> Void) async {
        await fallbackTTS.setOnFinished(handler)
    }

    func synthesize(text: String, voice: TTSVoice, rate: PlaybackRate) async -> TTSResult {
        synthesisGeneration += 1
        let synthesisID = synthesisGeneration
        let cacheKey = AudioCache.cacheKey(text: text, voice: voice, rate: rate)

        if let cachedAudio = await cache.get(cacheKey) {
            logger.debug("Cache hit for text synthesis")
            return .audioData(cachedAudio)
        }

        do {
            let audioData = try await edgeTTS.synthesize(text: text, voice: voice, rate: rate)

            await cache.set(cacheKey, audioData)
            logger.info("Edge TTS synthesis succeeded")
            return .audioData(audioData)
        } catch {
            logger.warning("Edge TTS synthesis failed: \(error.localizedDescription)")

            // A superseded or cancelled request must not start fallback speech
            // it can no longer manage.
            guard !Task.isCancelled, synthesisID == synthesisGeneration else {
                return .failed(error)
            }

            guard let utteranceGeneration = await fallbackTTS.startSpeaking(text: text, rate: rate) else {
                logger.error("Fallback TTS could not start")
                return .failed(error)
            }

            // Cancellation may have landed while speech was starting; clean up our own
            // utterance (generation-scoped, so a newer utterance is never touched).
            if Task.isCancelled {
                await fallbackTTS.stop(ifGeneration: utteranceGeneration)
                return .failed(error)
            }

            logger.info("Fallback TTS playback started")
            return .fallbackUsed(utteranceGeneration)
        }
    }

    /// Stops any in-progress fallback speech (cached/Edge audio is stopped via AudioPlayer).
    func stopPlayback() async {
        await fallbackTTS.stop()
    }

    /// Stops fallback speech only if the live utterance still matches `generation`.
    func stopFallback(generation: Int) async {
        await fallbackTTS.stop(ifGeneration: generation)
    }

    func pauseFallback() async {
        await fallbackTTS.pause()
    }

    func resumeFallback() async {
        await fallbackTTS.resume()
    }

    func shutdown() async {
        logger.info("Shutting down TTS manager")
        await fallbackTTS.stop()
    }
}
