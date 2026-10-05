import Foundation
// WhisperKit predates strict concurrency and exports `WhisperKit` as a
// non-Sendable class. It never leaves this actor, so the module's Sendable
// warnings are suppressed at the import rather than at each use site.
@preconcurrency import WhisperKit
import os

/// Whisper large-v3-turbo running on the Neural Engine through Core ML.
///
/// This is the engine that makes bilingual dictation work: Whisper transcribes a
/// sentence that switches between Chinese and English, which a locale-locked
/// recognizer structurally cannot.
///
/// Two adaptations exploit the fact that only two languages are ever possible:
/// detection is clamped to `{zh, en}` (see `resolveLanguage`), and the decoder is
/// primed with a language-appropriate prompt so Mandarin comes out Simplified.
actor WhisperKitTranscriber: DictationTranscribing {

    nonisolated let engine: DictationEngine = .whisper

    // MARK: - Services

    private var pipe: WhisperKit?
    private var loadedVariant: WhisperModelVariant?
    /// Shared across calls so two clips in flight cannot each start a download.
    /// The payload is deliberately `Void`: the loaded pipeline is handed over
    /// through `pipe`, so a non-Sendable `WhisperKit` never crosses out of the
    /// actor and back in.
    private var loadTask: Task<Void, Never>?
    private var lastLoadFailure: String?

    private var variant: WhisperModelVariant
    private var status: WhisperModelStatus = .notDownloaded
    private var onStatusChange: (@MainActor @Sendable (WhisperModelStatus) -> Void)?

    /// Last fraction actually published. Download progress is reported per
    /// received chunk, and every publish costs a hop onto the main actor and a
    /// SwiftUI invalidation — far more often than a percentage readout changes.
    private var publishedDownloadFraction: Double = -1

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "WhisperKitTranscriber")

    init(variant: WhisperModelVariant) {
        self.variant = variant
    }

    // MARK: - Lifecycle

    var isReady: Bool { pipe != nil && loadedVariant == variant }

    var modelStatus: WhisperModelStatus { status }

    func setStatusHandler(_ handler: @escaping @MainActor @Sendable (WhisperModelStatus) -> Void) {
        onStatusChange = handler
        publish(status)
    }

    /// Switches builds. The loaded model is dropped immediately so the next clip
    /// cannot be transcribed by the one the user just moved away from.
    func setVariant(_ newVariant: WhisperModelVariant) async {
        guard newVariant != variant else { return }
        logger.info("Whisper model changed to \(newVariant.rawValue, privacy: .public)")
        variant = newVariant
        loadTask?.cancel()
        loadTask = nil
        await pipe?.unloadModels()
        pipe = nil
        loadedVariant = nil
        publish(.notDownloaded)
    }

    func prepare() async throws {
        _ = try await loadedPipe()
    }

    func shutdown() async {
        loadTask?.cancel()
        loadTask = nil
        await pipe?.unloadModels()
        pipe = nil
        loadedVariant = nil
    }

    // MARK: - Transcription

    func transcribe(_ audio: DictationAudio, language: DictationLanguage) async throws -> DictationTranscript {
        let startedAt = ContinuousClock.now
        let pipe = try await loadedPipe()

        let resolved = await resolveLanguage(for: audio, requested: language, using: pipe)
        let options = decodingOptions(for: resolved)

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: audio.samples, decodeOptions: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Whisper transcription failed: \(error.localizedDescription, privacy: .public)")
            throw DictationError.transcriptionFailed(error.localizedDescription)
        }

        let raw = results.map(\.text).joined(separator: " ")
        let text = DictationTextCleaner.clean(raw, language: resolved)
        guard !text.isEmpty else { throw DictationError.emptyTranscript }

        let elapsed = startedAt.duration(to: .now)
        let processingDuration = TimeInterval(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        logger.info("""
        Whisper transcribed \(String(format: "%.2f", audio.duration), privacy: .public)s \
        as \(resolved.rawValue, privacy: .public) in \(String(format: "%.2f", processingDuration), privacy: .public)s
        """)

        return DictationTranscript(
            text: text,
            language: resolved,
            engine: .whisper,
            audioDuration: audio.duration,
            processingDuration: processingDuration
        )
    }

    // MARK: - Two-Language Detection

    /// Collapses Whisper's 99-way language posterior onto the only two options
    /// that exist here.
    ///
    /// Whisper's own `detectLanguage` regularly reports Mandarin as Cantonese,
    /// Japanese or Korean, and accented English as Dutch or Welsh — and it then
    /// transcribes in that wrong language. Reading just the `zh` and `en`
    /// probabilities off the same posterior removes that whole failure class for
    /// the cost of one encoder pass.
    private func resolveLanguage(
        for audio: DictationAudio,
        requested: DictationLanguage,
        using pipe: WhisperKit
    ) async -> DictationLanguage {
        guard requested == .auto else { return requested }

        do {
            // Note the upstream spelling: `detectLangauge` is the array-based overload.
            let detection = try await pipe.detectLangauge(audioArray: audio.samples)
            let probabilities = detection.langProbs

            // Cantonese and the `cmn`/`zh` variants all mean "Chinese" to us.
            let chinese = ["zh", "yue", "cmn"].compactMap { probabilities[$0] }.max() ?? 0
            let english = probabilities["en"] ?? 0

            let winner: DictationLanguage = chinese >= english ? .mandarin : .english
            let margin = abs(chinese - english)

            logger.info("""
            Language clamp: zh=\(String(format: "%.3f", chinese), privacy: .public) \
            en=\(String(format: "%.3f", english), privacy: .public) \
            raw=\(detection.language, privacy: .public) → \(winner.rawValue, privacy: .public)
            """)

            // A near-tie is usually a code-switched clip. Mandarin is the safer
            // bet there: Whisper keeps embedded English words verbatim inside a
            // Chinese transcription, but rendering Chinese under `en` produces
            // pinyin or dropped words.
            if margin < AppConstants.dictationLanguageConfidenceMargin {
                logger.info("Language margin too small — defaulting to Mandarin for the mixed case")
                return .mandarin
            }
            return winner
        } catch {
            logger.warning("Language detection failed, letting Whisper decide: \(error.localizedDescription, privacy: .public)")
            return .auto
        }
    }

    /// Deliberately no `promptTokens`. Priming the decoder with a
    /// Simplified-Chinese sentence is the usual trick for pulling Mandarin
    /// output away from Traditional characters, but `DictationTextCleaner`
    /// already does that deterministically with ICU's Hant→Hans transform — and
    /// a prompt costs the prefill cache (WhisperKit disables it whenever
    /// `promptTokens` is set) while risking the classic failure where Whisper
    /// echoes the prompt into a short clip's transcript.
    private func decodingOptions(for language: DictationLanguage) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language.whisperCode,
            // Dictation clips are seconds long, so the default five temperature
            // retries cost far more latency than the accuracy they recover.
            temperatureFallbackCount: 2,
            // Detection already happened above; letting the decoder redo it
            // would reintroduce the 99-way guess we just eliminated.
            detectLanguage: language.whisperCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Whisper's standard guard against transcribing room tone.
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
    }

    // MARK: - Model Loading

    /// Returns the loaded pipeline, downloading and loading it once. Concurrent
    /// callers await the same task instead of racing two 632 MB downloads.
    private func loadedPipe() async throws -> WhisperKit {
        if let pipe, loadedVariant == variant { return pipe }

        if loadTask == nil {
            loadTask = Task { await self.performLoad() }
        }
        await loadTask?.value

        guard let pipe, loadedVariant == variant else {
            throw DictationError.modelUnavailable(lastLoadFailure ?? "Whisper model unavailable.")
        }
        return pipe
    }

    /// Actor-isolated on purpose: the pipeline is built and stored without ever
    /// leaving this actor. The `await`s inside still let other calls in.
    private func performLoad() async {
        defer { loadTask = nil }

        let variant = self.variant
        lastLoadFailure = nil
        publishedDownloadFraction = 0
        publish(.downloading(fractionCompleted: 0))

        do {
            let folder = try await WhisperKit.download(
                variant: variant.rawValue,
                from: AppConstants.whisperModelRepository,
                progressCallback: { [weak self] progress in
                    // Only `self` is captured, and an actor reference is Sendable.
                    self?.reportDownloadProgress(progress.fractionCompleted)
                }
            )

            publish(.loading)

            let config = WhisperKitConfig(
                model: variant.rawValue,
                modelRepo: AppConstants.whisperModelRepository,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                // Core ML specializes a model to the chip on first load;
                // prewarming keeps that cost off the moment the user is waiting
                // on a transcript.
                prewarm: true,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)

            // A variant switch during the load makes this result stale.
            guard self.variant == variant else {
                await loaded.unloadModels()
                return
            }

            pipe = loaded
            loadedVariant = variant
            publish(.ready)
            logger.info("Whisper model ready: \(variant.rawValue, privacy: .public)")
        } catch {
            let message = Self.friendlyLoadFailure(error)
            lastLoadFailure = message
            publish(.failed(message))
            logger.error("Whisper model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated func reportDownloadProgress(_ fraction: Double) {
        Task { await self.publishDownloadProgress(fraction) }
    }

    /// Forwards progress only once it has moved by a percentage point, the
    /// smallest step any UI showing this renders.
    private func publishDownloadProgress(_ fraction: Double) {
        guard fraction - publishedDownloadFraction >= 0.01 else { return }
        publishedDownloadFraction = fraction
        publish(.downloading(fractionCompleted: fraction))
    }

    private static func friendlyLoadFailure(_ error: Error) -> String {
        let description = error.localizedDescription
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't download the Whisper model — check your internet connection"
        }
        return "Whisper model unavailable — \(description)"
    }

    private func publish(_ newStatus: WhisperModelStatus) {
        status = newStatus
        guard let onStatusChange else { return }
        Task { @MainActor in onStatusChange(newStatus) }
    }
}
