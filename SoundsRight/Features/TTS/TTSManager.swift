import Foundation
import os

actor TTSManager {
    private let kokoro = KokoroTTSService()
    private let edgeTTS = EdgeTTSService()
    private let fallbackTTS = FallbackTTSService()
    private let cache = AudioCache()
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "TTSManager")
    private var kokoroAvailable = false

    enum TTSResult {
        case audioData(Data)
        case fallbackUsed
        case failed(Error)
    }

    func initialize() async {
        logger.info("Initializing TTS manager")

        do {
            try await kokoro.startServer()

            let isRunning = await kokoro.isServerRunning()
            kokoroAvailable = isRunning

            if kokoroAvailable {
                logger.info("Kokoro server is running and available")
            } else {
                logger.warning("Kokoro server failed to start or is not responding")
            }
        } catch {
            logger.warning("Failed to initialize Kokoro: \(error.localizedDescription)")
            kokoroAvailable = false
        }
    }

    func synthesize(text: String, rate: PlaybackRate) async -> TTSResult {
        let cacheKey = AudioCache.cacheKey(text: text, rate: rate)

        if let cachedAudio = await cache.get(cacheKey) {
            logger.debug("Cache hit for text synthesis")
            return .audioData(cachedAudio)
        }

        if kokoroAvailable {
            do {
                let kokoroSpeed = rate.kokoroSpeed
                let audioData = try await kokoro.synthesize(text: text, speed: kokoroSpeed, voice: "af_heart")

                await cache.set(cacheKey, audioData)
                logger.info("Kokoro synthesis succeeded")
                return .audioData(audioData)
            } catch {
                logger.warning("Kokoro synthesis failed: \(error.localizedDescription)")
            }
        }

        do {
            let audioData = try await edgeTTS.synthesize(text: text, voice: .avaNeural, rate: rate)

            await cache.set(cacheKey, audioData)
            logger.info("Edge TTS synthesis succeeded")
            return .audioData(audioData)
        } catch {
            logger.warning("Edge TTS synthesis failed: \(error.localizedDescription)")
        }

        let fallbackRate = mapRateToFloat(rate)
        await fallbackTTS.speakAsync(text: text, rate: fallbackRate)
        logger.info("Fallback TTS playback succeeded")
        return .fallbackUsed
    }

    func shutdown() async {
        logger.info("Shutting down TTS manager")
        await kokoro.stopServer()
        fallbackTTS.stop()
    }

    private func mapRateToFloat(_ rate: PlaybackRate) -> Float {
        // AVSpeechSynthesizer rate: 0.0 (slowest) to 1.0 (fastest), 0.5 is normal
        switch rate {
        case .slow: return 0.35
        case .moderate: return 0.42
        case .normal: return 0.5
        case .fast: return 0.57
        }
    }
}
