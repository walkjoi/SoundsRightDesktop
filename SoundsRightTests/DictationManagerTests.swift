import XCTest
@testable import SoundsRight

/// Routing and warmup, driven through stub engines so no model is downloaded.
final class DictationManagerTests: XCTestCase {

    /// One second at a speaking level: long and loud enough to pass the
    /// too-short and silence checks that run before any engine.
    private static let speech = DictationAudio(
        samples: [Float](repeating: 0.3, count: 16_000),
        sampleRate: 16_000
    )

    // MARK: - Warmup

    /// A failed download must not leave Settings → Retry with nothing to do.
    func testAFailedWarmupCanBeRetried() async {
        let whisper = StubWhisper(prepareOutcomes: [false, true])
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        await manager.warmUpWhisper()
        await manager.settleWhisperWarmup()
        await manager.warmUpWhisper()
        await manager.settleWhisperWarmup()

        let calls = await whisper.prepareCalls
        let ready = await whisper.isReady
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(ready)
    }

    /// Clips leave a failed model to Settings → Retry, so one that can never
    /// load is not reloaded on every dictation.
    func testAClipDoesNotRetryAFailedModel() async throws {
        let whisper = StubWhisper(status: .failed("offline"))
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        let transcript = try await manager.transcribe(Self.speech, language: .english, preferredEngine: .whisper)
        await manager.settleWhisperWarmup()

        XCTAssertEqual(transcript.engine, DictationEngine.appleOnDevice)
        XCTAssertEqual(transcript.whisperFallback, WhisperFallback.modelUnavailable)
        let calls = await whisper.prepareCalls
        XCTAssertEqual(calls, 0)
    }

    func testAClipStartsADownloadThatHasNotBegun() async throws {
        let whisper = StubWhisper(status: .notDownloaded)
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        let transcript = try await manager.transcribe(Self.speech, language: .english, preferredEngine: .whisper)
        await manager.settleWhisperWarmup()

        XCTAssertEqual(transcript.whisperFallback, WhisperFallback.modelDownloading)
        let calls = await whisper.prepareCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Fallback Reasons

    /// A model switched away from between the readiness check and the clip is
    /// reported by its status, not as a clip Whisper failed on.
    func testAModelLostMidClipIsReportedByItsStatus() async throws {
        let whisper = StubWhisper(
            ready: true,
            status: .downloading(fractionCompleted: 0.1),
            transcribeError: .modelUnavailable("switched")
        )
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        let transcript = try await manager.transcribe(Self.speech, language: .english, preferredEngine: .whisper)

        XCTAssertEqual(transcript.engine, DictationEngine.appleOnDevice)
        XCTAssertEqual(transcript.whisperFallback, WhisperFallback.modelDownloading)
    }

    func testAWhisperFailureOnTheClipIsReportedAsSuch() async throws {
        let whisper = StubWhisper(ready: true, status: .ready, transcribeError: .transcriptionFailed("decoder"))
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        let transcript = try await manager.transcribe(Self.speech, language: .english, preferredEngine: .whisper)

        XCTAssertEqual(transcript.whisperFallback, WhisperFallback.transcriptionFailed)
    }

    func testAWhisperTranscriptCarriesNoFallback() async throws {
        let whisper = StubWhisper(ready: true, status: .ready)
        let manager = DictationManager(whisper: whisper, builtIn: StubBuiltIn())

        let transcript = try await manager.transcribe(Self.speech, language: .english, preferredEngine: .whisper)

        XCTAssertEqual(transcript.engine, DictationEngine.whisper)
        XCTAssertNil(transcript.whisperFallback)
    }
}

// MARK: - Stubs

/// Whisper stand-in: readiness and status are set by the test, and each
/// `prepare()` consumes the next scripted outcome (success once none is left).
private actor StubWhisper: WhisperTranscribing {
    nonisolated let engine: DictationEngine = .whisper

    private(set) var prepareCalls = 0
    private var prepareOutcomes: [Bool]
    private var ready: Bool
    private var status: WhisperModelStatus
    private let transcribeError: DictationError?

    init(
        ready: Bool = false,
        status: WhisperModelStatus = .notDownloaded,
        prepareOutcomes: [Bool] = [],
        transcribeError: DictationError? = nil
    ) {
        self.ready = ready
        self.status = status
        self.prepareOutcomes = prepareOutcomes
        self.transcribeError = transcribeError
    }

    var isReady: Bool { ready }

    var modelStatus: WhisperModelStatus { status }

    func setStatusHandler(_ handler: @escaping @MainActor @Sendable (WhisperModelStatus) -> Void) {}

    func setVariant(_ variant: WhisperModelVariant) {}

    func prepare() throws {
        prepareCalls += 1
        let succeeds = prepareOutcomes.isEmpty ? true : prepareOutcomes.removeFirst()
        guard succeeds else {
            status = .failed("offline")
            throw DictationError.modelUnavailable("offline")
        }
        ready = true
        status = .ready
    }

    func transcribe(_ audio: DictationAudio, language: DictationLanguage) throws -> DictationTranscript {
        if let transcribeError {
            throw transcribeError
        }
        return DictationTranscript(
            text: "whisper",
            language: .english,
            engine: .whisper,
            audioDuration: audio.duration,
            processingDuration: 0
        )
    }

    func shutdown() {}
}

/// Built-in engine stand-in: always answers.
private actor StubBuiltIn: DictationTranscribing {
    nonisolated let engine: DictationEngine = .appleOnDevice

    var isReady: Bool { true }

    func prepare() {}

    func transcribe(_ audio: DictationAudio, language: DictationLanguage) -> DictationTranscript {
        DictationTranscript(
            text: "built-in",
            language: .english,
            engine: .appleOnDevice,
            audioDuration: audio.duration,
            processingDuration: 0
        )
    }

    func shutdown() {}
}
