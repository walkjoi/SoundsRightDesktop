import AVFoundation
import Foundation
import Speech
import os

/// macOS built-in speech recognition: `SpeechAnalyzer` on macOS 26+, falling
/// back to `SFSpeechRecognizer`. Needs no download, so it covers the gap while
/// the Whisper model installs.
///
/// Both APIs are single-locale by construction (`SpeechTranscriber(locale:)`
/// takes exactly one). Because the candidate set here is only ever two, Auto can
/// afford to run zh-CN and en-US over the same clip concurrently and keep the
/// better hypothesis — an approach that would be untenable at 99 languages.
actor AppleSpeechTranscriber: DictationTranscribing {

    nonisolated let engine: DictationEngine = .appleOnDevice

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "AppleSpeechTranscriber")

    // MARK: - Lifecycle

    /// The built-in engines need no per-app model, so a clip can always start;
    /// macOS 26 asset installs are handled inline on first use.
    var isReady: Bool { true }

    func prepare() async {}

    func shutdown() async {}

    // MARK: - Permission

    static func requestSpeechAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Transcription

    func transcribe(_ audio: DictationAudio, language: DictationLanguage) async throws -> DictationTranscript {
        let startedAt = ContinuousClock.now

        let candidate: Hypothesis
        switch language {
        case .mandarin, .english:
            candidate = try await recognize(audio, as: language)
        case .auto:
            candidate = try await recognizeBothLanguages(audio)
        }

        let text = DictationTextCleaner.clean(candidate.text, language: candidate.language)
        guard !text.isEmpty else { throw DictationError.emptyTranscript }

        let elapsed = startedAt.duration(to: .now)
        let processingDuration = TimeInterval(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        return DictationTranscript(
            text: text,
            language: candidate.language,
            engine: .appleOnDevice,
            audioDuration: audio.duration,
            processingDuration: processingDuration
        )
    }

    /// Runs both locales over the same clip and keeps the better hypothesis.
    private func recognizeBothLanguages(_ audio: DictationAudio) async throws -> Hypothesis {
        async let mandarin = try? recognize(audio, as: .mandarin)
        async let english = try? recognize(audio, as: .english)
        let candidates = await [mandarin, english].compactMap { $0 }

        guard let best = Self.bestHypothesis(among: candidates, audioDuration: audio.duration) else {
            throw DictationError.emptyTranscript
        }

        logger.info("""
        Apple dual-locale pick: \(best.language.rawValue, privacy: .public) \
        from \(candidates.count, privacy: .public) hypotheses
        """)
        return best
    }

    private func recognize(_ audio: DictationAudio, as language: DictationLanguage) async throws -> Hypothesis {
        if #available(macOS 26, *) {
            do {
                return try await transcribeWithAnalyzer(audio, language: language)
            } catch {
                // An uninstallable locale asset is the expected reason to land
                // here; the legacy recognizer still covers zh-CN and en-US.
                logger.warning("""
                SpeechAnalyzer unavailable for \(language.localeIdentifier, privacy: .public), \
                using SFSpeechRecognizer: \(error.localizedDescription, privacy: .public)
                """)
            }
        }
        return try await transcribeWithLegacyRecognizer(audio, language: language)
    }

    // MARK: - SpeechAnalyzer (macOS 26+)

    @available(macOS 26, *)
    private func transcribeWithAnalyzer(
        _ audio: DictationAudio,
        language: DictationLanguage
    ) async throws -> Hypothesis {
        let locale = Locale(identifier: language.localeIdentifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.transcriptionFailed("\(language.localeIdentifier) is not supported by SpeechAnalyzer.")
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )

        try await installAssetsIfNeeded(for: transcriber)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = Self.convert(audio, to: analyzerFormat)
        else {
            throw DictationError.transcriptionFailed("Could not prepare audio for SpeechAnalyzer.")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results arrive on their own sequence while the analyzer consumes the
        // input, so collection has to be running before analysis starts.
        let collector = Task {
            var combined = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                combined.append(result.text)
            }
            return combined
        }

        // The buffer is yielded outside any @Sendable closure: AnalyzerInput is
        // Sendable, AVAudioPCMBuffer is not.
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        do {
            _ = try await analyzer.analyzeSequence(inputs)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw DictationError.transcriptionFailed(error.localizedDescription)
        }

        let attributed = try await collector.value
        return Hypothesis(
            text: String(attributed.characters),
            language: language,
            confidence: Self.meanConfidence(of: attributed)
        )
    }

    @available(macOS 26, *)
    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            logger.info("Installing SpeechAnalyzer assets")
            try await request.downloadAndInstall()
        case .unsupported:
            throw DictationError.transcriptionFailed("SpeechAnalyzer has no model for this locale.")
        @unknown default:
            throw DictationError.transcriptionFailed("SpeechAnalyzer reported an unknown asset state.")
        }
    }

    /// Length-weighted mean of the per-run confidence attribute, so a long
    /// confident run outweighs a short uncertain one.
    @available(macOS 26, *)
    private static func meanConfidence(of text: AttributedString) -> Double? {
        var weightedSum = 0.0
        var totalWeight = 0.0
        for run in text.runs {
            // Subscripted by attribute type rather than by dynamic member:
            // the key-path form captures a non-Sendable KeyPath, which strict
            // concurrency rejects.
            guard let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let weight = Double(text[run.range].characters.count)
            weightedSum += confidence * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    // MARK: - SFSpeechRecognizer (macOS 13–25)

    private func transcribeWithLegacyRecognizer(
        _ audio: DictationAudio,
        language: DictationLanguage
    ) async throws -> Hypothesis {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw DictationError.speechPermissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier)),
              recognizer.isAvailable
        else {
            throw DictationError.transcriptionFailed("Speech recognition is unavailable for \(language.displayName).")
        }
        guard let buffer = audio.makePCMBuffer() else {
            throw DictationError.transcriptionFailed("Could not prepare audio for recognition.")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // Keep dictation local. Server recognition also caps at roughly a
        // minute, which the 3-minute recording ceiling would exceed.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()

        // Resumed with plain Sendable values rather than the non-Sendable
        // `SFTranscription`, so nothing unsafe crosses back into the actor.
        let outcome: RecognitionOutcome = try await withCheckedThrowingContinuation { continuation in
            // The handler fires for partials, the final result, and errors; a
            // continuation may only be resumed once.
            let hasResumed = ResumeGuard()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if hasResumed.claim() { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                guard hasResumed.claim() else { return }
                let transcription = result.bestTranscription
                continuation.resume(returning: RecognitionOutcome(
                    text: transcription.formattedString,
                    confidences: transcription.segments.map { Double($0.confidence) }
                ))
            }
        }

        let confidences = outcome.confidences.filter { $0 > 0 }
        return Hypothesis(
            text: outcome.text,
            language: language,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
    }

    // MARK: - Hypothesis Scoring

    /// Sendable carrier for what `SFSpeechRecognizer` reported.
    private struct RecognitionOutcome: Sendable {
        let text: String
        let confidences: [Double]
    }

    struct Hypothesis: Sendable {
        let text: String
        let language: DictationLanguage
        /// Engine-reported confidence; nil when the engine reports none, which
        /// on-device `SFSpeechRecognizer` routinely does.
        let confidence: Double?
    }

    /// Picks between the Chinese and English readings of the same clip.
    ///
    /// Script purity alone cannot decide this — each recognizer emits its own
    /// script whether or not it understood anything. What separates a real
    /// transcription from gibberish is *how much* text came out relative to the
    /// clip length: a recognizer that did not understand the audio produces far
    /// too little. That rate check carries the decision, with engine confidence
    /// and a purity sanity-check adjusting it.
    static func bestHypothesis(among candidates: [Hypothesis], audioDuration: TimeInterval) -> Hypothesis? {
        let scored = candidates
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (hypothesis: $0, score: score($0, audioDuration: audioDuration)) }

        return scored.max { $0.score < $1.score }?.hypothesis
    }

    static func score(_ hypothesis: Hypothesis, audioDuration: TimeInterval) -> Double {
        // A missing confidence is neutral, not bad.
        let confidence = hypothesis.confidence ?? 0.5
        return 0.50 * confidence
            + 0.35 * rateScore(hypothesis, audioDuration: audioDuration)
            + 0.15 * purityScore(hypothesis)
    }

    /// How close the output rate is to natural speech for that language:
    /// roughly 4 characters per second for Mandarin, 2.5 words per second for
    /// English. Peaks at 1 and decays smoothly in both directions.
    private static func rateScore(_ hypothesis: Hypothesis, audioDuration: TimeInterval) -> Double {
        guard audioDuration > 0 else { return 0 }

        let observed: Double
        let expected: Double
        switch hypothesis.language {
        case .mandarin, .auto:
            let characters = DictationTextCleaner.meaningfulScalarCount(hypothesis.text)
            observed = Double(characters) / audioDuration
            expected = 4.0
        case .english:
            let words = hypothesis.text.split(whereSeparator: { $0.isWhitespace }).count
            observed = Double(words) / audioDuration
            expected = 2.5
        }

        guard observed > 0 else { return 0 }
        return exp(-abs(log(observed / expected)))
    }

    /// Penalizes a hypothesis written in the wrong script for its language —
    /// Han characters in an English result, or a "Chinese" result that came
    /// back as Latin because the recognizer gave up.
    private static func purityScore(_ hypothesis: Hypothesis) -> Double {
        let hanRatio = DictationTextCleaner.hanRatio(hypothesis.text)
        switch hypothesis.language {
        case .mandarin, .auto:
            return hanRatio
        case .english:
            return 1 - hanRatio
        }
    }

    // MARK: - Audio Conversion

    private static func convert(_ audio: DictationAudio, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = audio.makePCMBuffer() else { return nil }
        if source.format == format { return source }

        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return source
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// One-shot latch so a multi-call recognition handler resumes its continuation
/// exactly once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
