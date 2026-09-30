import XCTest
@testable import SoundsRight

// MARK: - Transcript Cleanup

final class DictationTextCleanerTests: XCTestCase {

    func testStripsNonSpeechAnnotations() {
        XCTAssertEqual(
            DictationTextCleaner.clean("(upbeat music) Hello there [BLANK_AUDIO]", language: .english),
            "Hello there"
        )
        XCTAssertEqual(
            DictationTextCleaner.clean("♪♪♪ Let's begin", language: .english),
            "Let's begin"
        )
        XCTAssertEqual(
            DictationTextCleaner.clean("（音乐）开始吧", language: .mandarin),
            "开始吧"
        )
    }

    func testConvertsTraditionalToSimplifiedForMandarin() {
        XCTAssertEqual(
            DictationTextCleaner.clean("這個functionu寫得很好", language: .mandarin),
            "这个functionu写得很好"
        )
    }

    func testLeavesEnglishUntouchedWhenLanguageIsEnglish() {
        let text = "The quick brown fox."
        XCTAssertEqual(DictationTextCleaner.clean(text, language: .english), text)
    }

    func testRemovesSpacesBetweenChineseCharactersButKeepsCodeSwitchSpacing() {
        // Whisper sometimes joins Chinese sub-word pieces with spaces; the
        // spaces around an embedded English word must survive.
        XCTAssertEqual(
            DictationTextCleaner.removeSpacesBetweenCJK("我 想 把 这个 function 改成 async 的"),
            "我想把这个 function 改成 async 的"
        )
    }

    func testCollapsesRepeatedWhitespace() {
        XCTAssertEqual(
            DictationTextCleaner.clean("hello    world", language: .english),
            "hello world"
        )
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(DictationTextCleaner.clean("   \n  ", language: .auto), "")
    }

    func testHanRatio() {
        XCTAssertEqual(DictationTextCleaner.hanRatio("你好世界"), 1.0, accuracy: 0.001)
        XCTAssertEqual(DictationTextCleaner.hanRatio("hello world"), 0.0, accuracy: 0.001)
        // Punctuation and whitespace are excluded, so this is 2 Han of 4 chars.
        XCTAssertEqual(DictationTextCleaner.hanRatio("ab 你好!"), 0.5, accuracy: 0.001)
        XCTAssertEqual(DictationTextCleaner.hanRatio(""), 0.0, accuracy: 0.001)
    }
}

// MARK: - Two-Language Arbitration

final class DictationLanguageArbitrationTests: XCTestCase {

    private typealias Hypothesis = AppleSpeechTranscriber.Hypothesis

    /// Five seconds of Mandarin: the zh recognizer produces a plausible number
    /// of Han characters, the en recognizer produces a few junk words.
    func testPicksMandarinForChineseAudio() {
        let candidates = [
            Hypothesis(text: "今天天气很好我们出去走走吧", language: .mandarin, confidence: nil),
            Hypothesis(text: "gin tin chi", language: .english, confidence: nil)
        ]
        let best = AppleSpeechTranscriber.bestHypothesis(among: candidates, audioDuration: 3.2)
        XCTAssertEqual(best?.language, .mandarin)
    }

    /// The mirror case: a natural English word rate beats Han gibberish.
    func testPicksEnglishForEnglishAudio() {
        let candidates = [
            Hypothesis(text: "啊哦", language: .mandarin, confidence: nil),
            Hypothesis(text: "could you please open the settings window", language: .english, confidence: nil)
        ]
        let best = AppleSpeechTranscriber.bestHypothesis(among: candidates, audioDuration: 2.8)
        XCTAssertEqual(best?.language, .english)
    }

    func testEngineConfidenceBreaksOtherwiseSimilarHypotheses() {
        let candidates = [
            Hypothesis(text: "打开设置窗口好吗", language: .mandarin, confidence: 0.95),
            Hypothesis(text: "da kai she zhi", language: .english, confidence: 0.20)
        ]
        let best = AppleSpeechTranscriber.bestHypothesis(among: candidates, audioDuration: 2.0)
        XCTAssertEqual(best?.language, .mandarin)
    }

    func testEmptyHypothesesAreDiscarded() {
        let candidates = [
            Hypothesis(text: "   ", language: .mandarin, confidence: 0.99),
            Hypothesis(text: "hello world there", language: .english, confidence: 0.1)
        ]
        let best = AppleSpeechTranscriber.bestHypothesis(among: candidates, audioDuration: 1.2)
        XCTAssertEqual(best?.language, .english)
    }

    func testNoCandidatesYieldsNil() {
        XCTAssertNil(AppleSpeechTranscriber.bestHypothesis(among: [], audioDuration: 1))
        XCTAssertNil(AppleSpeechTranscriber.bestHypothesis(
            among: [Hypothesis(text: "", language: .english, confidence: 1)],
            audioDuration: 1
        ))
    }

    /// A wildly over-long hypothesis is as suspicious as an empty one.
    func testImplausiblyFastOutputScoresBelowNaturalOutput() {
        let natural = Hypothesis(text: "open the door", language: .english, confidence: nil)
        let runaway = Hypothesis(
            text: String(repeating: "word ", count: 200),
            language: .english,
            confidence: nil
        )
        XCTAssertGreaterThan(
            AppleSpeechTranscriber.score(natural, audioDuration: 1.2),
            AppleSpeechTranscriber.score(runaway, audioDuration: 1.2)
        )
    }
}

// MARK: - Language Mapping

final class DictationLanguageTests: XCTestCase {

    func testEngineCodesMapOntoTheTwoSupportedLanguages() {
        XCTAssertEqual(DictationLanguage.from(engineCode: "zh"), .mandarin)
        XCTAssertEqual(DictationLanguage.from(engineCode: "zh-Hans"), .mandarin)
        // Whisper reports Mandarin as Cantonese often enough that both map home.
        XCTAssertEqual(DictationLanguage.from(engineCode: "yue"), .mandarin)
        XCTAssertEqual(DictationLanguage.from(engineCode: "en-US"), .english)
        XCTAssertNil(DictationLanguage.from(engineCode: "ja"))
        XCTAssertNil(DictationLanguage.from(engineCode: nil))
    }

    func testAutoLeavesTheWhisperLanguageTokenUnset() {
        XCTAssertNil(DictationLanguage.auto.whisperCode)
        XCTAssertEqual(DictationLanguage.mandarin.whisperCode, "zh")
        XCTAssertEqual(DictationLanguage.english.whisperCode, "en")
    }
}

// MARK: - Audio

final class DictationAudioTests: XCTestCase {

    func testDurationDerivesFromSampleCount() {
        let audio = DictationAudio(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
        XCTAssertEqual(audio.duration, 0.5, accuracy: 0.0001)
    }

    func testPeakAndRMS() {
        let audio = DictationAudio(samples: [0, 0.5, -0.9, 0.1], sampleRate: 16_000)
        XCTAssertEqual(audio.peakAmplitude, 0.9, accuracy: 0.0001)
        XCTAssertGreaterThan(audio.rootMeanSquare, 0)
        XCTAssertLessThan(audio.rootMeanSquare, audio.peakAmplitude)
    }

    func testSilenceIsDistinguishableFromSpeech() {
        let silence = DictationAudio(samples: [Float](repeating: 0.001, count: 16_000), sampleRate: 16_000)
        let speech = DictationAudio(samples: [Float](repeating: 0.4, count: 16_000), sampleRate: 16_000)
        XCTAssertLessThan(silence.peakAmplitude, AppConstants.dictationSilencePeakThreshold)
        XCTAssertGreaterThan(speech.peakAmplitude, AppConstants.dictationSilencePeakThreshold)
    }

    func testWavDataHasAValidHeaderAndPayload() {
        let sampleCount = 100
        let audio = DictationAudio(
            samples: [Float](repeating: 0.25, count: sampleCount),
            sampleRate: 16_000
        )
        let data = audio.wavData()

        XCTAssertEqual(data.count, 44 + sampleCount * 2)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")

        let declaredPayload = data.subdata(in: 40..<44).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        XCTAssertEqual(Int(declaredPayload), sampleCount * 2)
    }

    /// Full-scale input must not wrap: +1.0 has to clamp to Int16.max, not
    /// overflow into a large negative sample.
    func testFullScaleSamplesDoNotWrap() {
        let audio = DictationAudio(samples: [1.0, -1.0], sampleRate: 16_000)
        let data = audio.wavData()
        let first = data.subdata(in: 44..<46).withUnsafeBytes { $0.loadUnaligned(as: Int16.self).littleEndian }
        let second = data.subdata(in: 46..<48).withUnsafeBytes { $0.loadUnaligned(as: Int16.self).littleEndian }
        XCTAssertEqual(first, Int16.max)
        XCTAssertEqual(second, Int16.min)
    }

    func testEmptyAudioProducesHeaderOnlyWav() {
        let audio = DictationAudio(samples: [], sampleRate: 16_000)
        XCTAssertEqual(audio.duration, 0)
        XCTAssertEqual(audio.wavData().count, 44)
        XCTAssertNil(audio.makePCMBuffer())
    }
}
