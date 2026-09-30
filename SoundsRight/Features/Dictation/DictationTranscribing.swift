import Foundation

/// A speech-to-text backend. Implementations are actors, so every requirement
/// is satisfied by an isolated `async` method.
protocol DictationTranscribing: Sendable {
    nonisolated var engine: DictationEngine { get }

    /// True when a clip handed over right now would transcribe without first
    /// downloading or loading anything. `DictationManager` uses this to decide
    /// whether to fall back rather than make the user wait.
    var isReady: Bool { get async }

    /// Loads whatever the backend needs, ahead of the first clip.
    func prepare() async throws

    func transcribe(_ audio: DictationAudio, language: DictationLanguage) async throws -> DictationTranscript

    /// Releases models and caches.
    func shutdown() async
}

// MARK: - Transcript Cleanup

/// Normalization shared by every backend. Kept separate from the backends so
/// the rules are defined — and tested — in exactly one place.
enum DictationTextCleaner {

    /// Trims the result and removes the artifacts that make a transcript
    /// unusable as typed input.
    static func clean(_ text: String, language: DictationLanguage?) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        cleaned = stripBracketedAnnotations(cleaned)
        cleaned = collapseWhitespace(cleaned)

        if language == .mandarin {
            cleaned = simplified(cleaned)
            cleaned = removeSpacesBetweenCJK(cleaned)
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper narrates non-speech audio as "(music)", "[BLANK_AUDIO]" or
    /// "♪♪♪". None of that belongs in dictated text.
    private static func stripBracketedAnnotations(_ text: String) -> String {
        var result = text
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"（[^）]*）"#, #"【[^】]*】"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "♪", with: "")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n+ *"#, with: "\n", options: .regularExpression)
    }

    /// Whisper emits Traditional characters for Mandarin often enough to matter.
    /// ICU's Hant→Hans transform is deterministic and leaves Latin untouched, so
    /// a code-switched sentence keeps its English words intact.
    static func simplified(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        guard CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false) else { return text }
        return mutable as String
    }

    /// Whisper tokenizes Chinese into sub-word pieces and sometimes rejoins them
    /// with spaces ("我 想 要"). Spaces bordering a Latin word are kept, because
    /// those are the code-switch boundaries that should stay spaced.
    static func removeSpacesBetweenCJK(_ text: String) -> String {
        let cjk = #"\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、（）《》「」“”‘’"#
        return text.replacingOccurrences(
            of: "([\(cjk)]) +(?=[\(cjk)])",
            with: "$1",
            options: .regularExpression
        )
    }

    /// Share of characters that are Han, ignoring whitespace and punctuation.
    /// Used to sanity-check which of two competing hypotheses matches its
    /// claimed language.
    static func hanRatio(_ text: String) -> Double {
        let meaningful = text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
        guard !meaningful.isEmpty else { return 0 }
        let hanCount = meaningful.filter { isHan($0) }.count
        return Double(hanCount) / Double(meaningful.count)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // Extension A
             0xF900...0xFAFF:   // Compatibility Ideographs
            return true
        default:
            return false
        }
    }
}
