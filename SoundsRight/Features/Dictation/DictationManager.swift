import Foundation
import os

/// Routes a captured clip to a transcription engine, mirroring the
/// cache → Edge → AVSpeech shape of `TTSManager`.
///
/// The chain exists because the preferred engine needs a 632 MB download before
/// its first use. Rather than blocking the user behind that, a clip recorded
/// while Whisper is still installing is transcribed by the built-in engine, and
/// the download continues in the background.
actor DictationManager {

    private let whisper: WhisperKitTranscriber
    private let appleSpeech = AppleSpeechTranscriber()

    /// The download/load running in the background, so the clip that triggered
    /// it is not held up and repeated calls while it runs do not stack. Cleared
    /// when the attempt ends, whether it succeeded or failed: repeating a
    /// success costs nothing, and a failure must not leave Settings → Retry
    /// with nothing to do.
    private var whisperWarmupTask: Task<Void, Never>?
    /// Identifies the warmup `whisperWarmupTask` holds, so one abandoned by a
    /// model switch cannot clear the slot of the warmup that replaced it.
    private var whisperWarmupGeneration = 0

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "DictationManager")

    init(modelVariant: WhisperModelVariant) {
        whisper = WhisperKitTranscriber(variant: modelVariant)
    }

    // MARK: - Configuration

    func setModelStatusHandler(_ handler: @escaping @MainActor @Sendable (WhisperModelStatus) -> Void) async {
        await whisper.setStatusHandler(handler)
    }

    func setModelVariant(_ variant: WhisperModelVariant) async {
        abandonWhisperWarmup()
        await whisper.setVariant(variant)
    }

    /// Starts the model download/load unless an attempt is already running.
    /// Safe to call on every launch and settings change: a loaded model
    /// answers at once, and a failed attempt leaves nothing behind that would
    /// stop the next call from retrying.
    func warmUpWhisper() {
        guard whisperWarmupTask == nil else { return }
        whisperWarmupGeneration += 1
        let generation = whisperWarmupGeneration
        whisperWarmupTask = Task { await self.runWhisperWarmup(generation: generation) }
    }

    func shutdown() async {
        abandonWhisperWarmup()
        await whisper.shutdown()
        await appleSpeech.shutdown()
    }

    // MARK: - Transcription

    func transcribe(
        _ audio: DictationAudio,
        language: DictationLanguage,
        preferredEngine: DictationEngine
    ) async throws -> DictationTranscript {
        try validate(audio)

        switch preferredEngine {
        case .appleOnDevice:
            return try await appleSpeech.transcribe(audio, language: language)

        case .whisper:
            // Only wait on Whisper when it can answer now. Otherwise the
            // built-in engine handles this clip while the model installs.
            guard await whisper.isReady else {
                let status = await whisper.modelStatus
                let fallback = WhisperFallback(modelStatus: status)
                // A clip starts a download that has not begun, but does not
                // retry one that failed: that is Settings → Retry's job (or
                // the next launch's), so a model that can never load is not
                // reloaded in the background every time the user dictates.
                if fallback != .modelUnavailable {
                    warmUpWhisper()
                }
                logger.info("Whisper not loaded yet — transcribing with the built-in engine")
                return try await transcribeWithBuiltInEngine(audio, language: language, fallback: fallback)
            }

            do {
                return try await whisper.transcribe(audio, language: language)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DictationError where error == .emptyTranscript {
                // Whisper heard nothing; a second engine would only invent text.
                throw error
            } catch {
                logger.warning("""
                Whisper failed, falling back to the built-in engine: \
                \(error.localizedDescription, privacy: .public)
                """)
                return try await transcribeWithBuiltInEngine(
                    audio,
                    language: language,
                    fallback: .transcriptionFailed
                )
            }
        }
    }

    /// The built-in engine standing in for Whisper, with the reason recorded
    /// on the transcript so the toast can say why.
    private func transcribeWithBuiltInEngine(
        _ audio: DictationAudio,
        language: DictationLanguage,
        fallback: WhisperFallback
    ) async throws -> DictationTranscript {
        var transcript = try await appleSpeech.transcribe(audio, language: language)
        transcript.whisperFallback = fallback
        return transcript
    }

    /// Rejects clips no engine should see. Whisper in particular will produce a
    /// fluent, entirely invented sentence from room tone, so silence is filtered
    /// here rather than explained away afterwards.
    private func validate(_ audio: DictationAudio) throws {
        guard audio.duration >= AppConstants.dictationMinDuration else {
            throw DictationError.tooShort
        }
        guard audio.peakAmplitude >= AppConstants.dictationSilencePeakThreshold else {
            logger.info("Clip rejected as silence (peak \(audio.peakAmplitude, privacy: .public))")
            throw DictationError.silent
        }
    }

    // MARK: - Whisper Warmup

    private func runWhisperWarmup(generation: Int) async {
        do {
            try await whisper.prepare()
        } catch {
            // A warmup abandoned by a model switch or shutdown fails by design.
            if !Task.isCancelled {
                logger.warning("Whisper warm-up failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Only the warmup that still owns the slot may clear it.
        if generation == whisperWarmupGeneration {
            whisperWarmupTask = nil
        }
    }

    /// Disowns the running warmup. The transcriber abandons the download
    /// itself; this only keeps the old attempt from clearing its successor's
    /// slot when it finally returns.
    private func abandonWhisperWarmup() {
        whisperWarmupGeneration += 1
        whisperWarmupTask?.cancel()
        whisperWarmupTask = nil
    }
}
