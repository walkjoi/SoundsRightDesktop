import Foundation
import os

actor TTSManager {
    private let edgeTTS = EdgeTTSService()
    private let fallbackTTS = FallbackTTSService()
    private let cache = AudioCache()
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "TTSManager")

    enum TTSResult {
        case audioData(Data)
        case fallbackUsed
        case failed(Error)
    }

    func synthesize(text: String, rate: PlaybackRate) async -> TTSResult {
        let cacheKey = AudioCache.cacheKey(text: text, rate: rate)

        if let cachedAudio = await cache.get(cacheKey) {
            logger.debug("Cache hit for text synthesis")
            return .audioData(cachedAudio)
        }

        do {
            let audioData = try await edgeTTS.synthesize(text: text, voice: .avaNeural, rate: rate)

            await cache.set(cacheKey, audioData)
            logger.info("Edge TTS synthesis succeeded")
            return .audioData(audioData)
        } catch {
            logger.warning("Edge TTS synthesis failed: \(error.localizedDescription)")
        }

        await fallbackTTS.speakAsync(text: text, rate: Float(rate.rawValue))
        logger.info("Fallback TTS playback succeeded")
        return .fallbackUsed
    }

    func shutdown() async {
        logger.info("Shutting down TTS manager")
        fallbackTTS.stop()
    }
}
