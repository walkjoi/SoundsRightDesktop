import Foundation

/// The only two languages this app transcribes. Fixing the candidate set at two
/// is what lets `WhisperKitTranscriber` clamp Whisper's language detection to
/// `{zh, en}` instead of trusting its 99-way guess — the single biggest accuracy
/// win available here, because Mandarin is routinely misdetected as Cantonese,
/// Japanese or Korean, and accented English as Dutch or Welsh.
enum DictationLanguage: String, CaseIterable, Identifiable {
    case auto
    case mandarin
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .mandarin: return "中文"
        case .english: return "English"
        }
    }

    /// Whisper's two-letter language token, or nil when detection is left to
    /// the model (still clamped to `DictationLanguage.detectionCandidates`).
    var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .mandarin: return "zh"
        case .english: return "en"
        }
    }

    /// Locale for the Apple speech engines, which are always single-language.
    var localeIdentifier: String {
        switch self {
        case .auto, .mandarin: return "zh-CN"
        case .english: return "en-US"
        }
    }

    /// The fixed two-way choice every auto-detect collapses to.
    static let detectionCandidates: [DictationLanguage] = [.mandarin, .english]

    /// Maps a code reported by an engine back onto our two-way enum.
    static func from(engineCode: String?) -> DictationLanguage? {
        guard let code = engineCode?.lowercased() else { return nil }
        if code.hasPrefix("zh") || code.hasPrefix("yue") || code.hasPrefix("cmn") { return .mandarin }
        if code.hasPrefix("en") { return .english }
        return nil
    }

    var settingsNote: String {
        switch self {
        case .auto:
            return "Each clip is classified as Chinese or English before transcription — no other language is ever considered."
        case .mandarin:
            return "Skips detection and always transcribes Mandarin. Fastest, and the safest choice if you rarely dictate English."
        case .english:
            return "Skips detection and always transcribes English."
        }
    }
}

/// Which speech-to-text backend runs the clip.
enum DictationEngine: String, CaseIterable, Identifiable {
    /// Whisper large-v3-turbo via Core ML (WhisperKit). Handles a sentence that
    /// mixes Chinese and English, which the locale-locked Apple engines cannot.
    case whisper
    /// macOS built-in recognition. No download, so it covers the gap before the
    /// Whisper model has finished installing.
    case appleOnDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .appleOnDevice: return "macOS built-in"
        }
    }

    var settingsNote: String {
        switch self {
        case .whisper:
            return "Best accuracy, and the only engine that keeps English words inside a Chinese sentence. Needs a one-time model download."
        case .appleOnDevice:
            return "No download and lower latency, but it transcribes one language at a time — English words in a Chinese sentence come out as Chinese characters."
        }
    }
}

/// Core ML Whisper builds offered in Settings, all from `argmaxinc/whisperkit-coreml`.
/// Only large-v3-class models transcribe Mandarin well, so the small build is
/// labelled honestly rather than presented as a peer.
enum WhisperModelVariant: String, CaseIterable, Identifiable {
    case largeV3TurboCompressed = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case small = "openai_whisper-small_216MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3TurboCompressed: return "Balanced"
        case .largeV3Turbo: return "Accurate"
        case .small: return "Fast"
        }
    }

    var downloadSizeDescription: String {
        switch self {
        case .largeV3TurboCompressed: return "632 MB"
        case .largeV3Turbo: return "1.5 GB"
        case .small: return "216 MB"
        }
    }

    var settingsNote: String {
        switch self {
        case .largeV3TurboCompressed:
            return "Whisper large-v3-turbo, quantized. Strong Mandarin and English at a fraction of the download."
        case .largeV3Turbo:
            return "Full-precision large-v3-turbo. Marginally better than Balanced, at more than twice the size."
        case .small:
            return "Quickest to download and run, but noticeably weaker at Mandarin. Fine for English-only dictation."
        }
    }
}

/// Where the Whisper model stands. Drives both the Settings row and the HUD's
/// explanation of why a clip fell back to the Apple engine.
enum WhisperModelStatus: Equatable {
    case notDownloaded
    case downloading(fractionCompleted: Double)
    case loading
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .notDownloaded, .ready, .failed: return false
        }
    }
}

/// Lifecycle of one dictation, as the HUD presents it.
enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case failed(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .failed: return true
        case .idle: return false
        }
    }
}

/// A finished transcription, before it is inserted at the caret.
struct DictationTranscript: Sendable {
    let text: String
    /// What the engine actually transcribed, once clamped to our two languages.
    let language: DictationLanguage?
    let engine: DictationEngine
    /// Length of the captured audio.
    let audioDuration: TimeInterval
    /// Wall-clock time from "user stopped talking" to "text ready".
    let processingDuration: TimeInterval
}

/// Everything that can go wrong between the hotkey and the inserted text.
enum DictationError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case noAudioInput
    case recordingFailed(String)
    case tooShort
    case silent
    case modelUnavailable(String)
    case transcriptionFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required to dictate."
        case .speechPermissionDenied:
            return "Speech recognition access is required for the macOS built-in engine."
        case .noAudioInput:
            return "No microphone is available."
        case .recordingFailed(let reason):
            return reason
        case .tooShort:
            return "That was too short to transcribe."
        case .silent:
            return "Didn't hear anything."
        case .modelUnavailable(let reason):
            return reason
        case .transcriptionFailed(let reason):
            return reason
        case .emptyTranscript:
            return "Nothing was said."
        }
    }

    /// Short, cursor-anchored wording. A dictation that produces no text must
    /// still say so — the same rule the lookup flow follows.
    var toastMessage: String {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access needed — enable SoundsRight in System Settings → Privacy & Security → Microphone"
        case .speechPermissionDenied:
            return "Speech recognition access needed — enable it in System Settings → Privacy & Security"
        case .noAudioInput:
            return "No microphone found — connect one and try again"
        case .recordingFailed(let reason):
            return "Recording failed — \(reason)"
        case .tooShort:
            return "Too short — hold the shortcut while you speak"
        case .silent, .emptyTranscript:
            return "Didn't catch that — try again"
        case .modelUnavailable(let reason):
            return reason
        case .transcriptionFailed:
            return "Couldn't transcribe that — try again"
        }
    }
}
