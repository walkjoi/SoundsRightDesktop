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

    /// Runs the download/load once, in the background, without holding up the
    /// clip that triggered it.
    private var whisperWarmupTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "DictationManager")

    init(modelVariant: WhisperModelVariant) {
        whisper = WhisperKitTranscriber(variant: modelVariant)
    }

    // MARK: - Configuration

    func setModelStatusHandler(_ handler: @escaping @MainActor @Sendable (WhisperModelStatus) -> Void) async {
        await whisper.setStatusHandler(handler)
    }

    func setModelVariant(_ variant: WhisperModelVariant) async {
        whisperWarmupTask?.cancel()
        whisperWarmupTask = nil
        await whisper.setVariant(variant)
    }

    /// Starts the model download/load if it has not run yet. Safe to call on
    /// every launch and every settings change.
    func warmUpWhisper() {
        guard whisperWarmupTask == nil else { return }
        whisperWarmupTask = Task { [whisper, logger] in
            do {
                try await whisper.prepare()
            } catch {
                logger.warning("Whisper warm-up failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func shutdown() async {
        whisperWarmupTask?.cancel()
        whisperWarmupTask = nil
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
                warmUpWhisper()
                logger.info("Whisper not loaded yet — transcribing with the built-in engine")
                return try await appleSpeech.transcribe(audio, language: language)
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
                return try await appleSpeech.transcribe(audio, language: language)
            }
        }
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
}
