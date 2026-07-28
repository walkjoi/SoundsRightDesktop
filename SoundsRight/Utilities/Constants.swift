import Foundation

enum TTSVoice: String, CaseIterable, Identifiable {
    case avaNeural = "en-US-AvaNeural"
    case emmaMultilingualNeural = "en-US-EmmaMultilingualNeural"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .avaNeural:
            return "Ava"
        case .emmaMultilingualNeural:
            return "Emma"
        }
    }

    /// True for voices that auto-detect the input language instead of always
    /// speaking en-US. The Edge readaloud endpoint rejects the `<lang>` SSML
    /// element that would pin the language, so detection cannot be overridden.
    var isMultilingual: Bool {
        switch self {
        case .avaNeural:
            return false
        case .emmaMultilingualNeural:
            return true
        }
    }

    /// Shown under the voice picker in Settings.
    var pronunciationNote: String {
        switch self {
        case .avaNeural:
            return "American English only — single words always get the American pronunciation."
        case .emmaMultilingualNeural:
            return "Multilingual — guesses the language from the text, so an isolated word (e.g. “lap”) may be read as another language."
        }
    }
}

enum PlaybackRate: Double, CaseIterable, Comparable, Identifiable {
    case slow = 0.5
    case moderate = 0.75
    case normal = 1.0
    case fast = 1.25
    case faster = 1.5

    static let defaultOptions: [PlaybackRate] = [.slow, .moderate, .normal, .fast, .faster]

    var id: Double { rawValue }

    var ssmlRate: String {
        let percentage = Int(((rawValue - 1.0) * 100).rounded())
        return percentage >= 0 ? "+\(percentage)%" : "\(percentage)%"
    }

    var displayLabel: String {
        switch self {
        case .slow:
            return "0.5x"
        case .moderate:
            return "0.75x"
        case .normal:
            return "1.0x"
        case .fast:
            return "1.25x"
        case .faster:
            return "1.5x"
        }
    }

    static func < (lhs: PlaybackRate, rhs: PlaybackRate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func options(from rawValue: String) -> [PlaybackRate] {
        let parsedRates = rawValue
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .compactMap(PlaybackRate.init(rawValue:))

        return sanitized(parsedRates)
    }

    static func storageValue(for rates: [PlaybackRate]) -> String {
        sanitized(rates)
            .map { String($0.rawValue) }
            .joined(separator: ",")
    }

    static func sanitized(_ rates: [PlaybackRate]) -> [PlaybackRate] {
        let uniqueRates = Array(Set(rates)).sorted()
        return uniqueRates.isEmpty ? defaultOptions : uniqueRates
    }
}

enum ActivationMode: String, CaseIterable {
    case translation = "translation"
    case soundOnly = "soundOnly"

    var displayName: String {
        switch self {
        case .translation: return "Translation"
        case .soundOnly: return "Sound Only"
        }
    }
}

/// How lookups are initiated: the global keyboard shortcuts only (default), or
/// additionally by selecting text with the mouse and letting the pointer rest.
enum ActivationTrigger: String, CaseIterable, Identifiable {
    case shortcut = "shortcut"
    case hover = "hover"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortcut: return "Keyboard Shortcut"
        case .hover: return "Hover"
        }
    }

    /// Shown under the trigger picker in Settings.
    var settingsNote: String {
        switch self {
        case .shortcut:
            return "Lookups start when you press one of the shortcuts above."
        case .hover:
            return "Select text with the mouse, then rest the pointer for a moment to translate and speak it. The shortcuts keep working too."
        }
    }
}

/// Who initiated an activation. Hover triggers fire speculatively (any mouse
/// selection arms them), so their failures stay quiet instead of toasting.
enum ActivationSource {
    case userInitiated
    case hover
}

enum AppConstants {
    static let dictionaryAPIBaseURL = "https://api.dictionaryapi.dev/api/v2/entries/en/"
    static let edgeTTSEndpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    /// Idle timeout between WebSocket frames during Edge TTS synthesis.
    static let edgeTTSIdleTimeout: TimeInterval = 10
    /// Hard ceiling on a whole Edge TTS synthesis, even if the server keeps trickling frames.
    static let edgeTTSSynthesisDeadline: TimeInterval = 30
    static let maxInputLength = 1000
    /// How long to wait for the synthesized Cmd+C to land on the pasteboard.
    static let pasteboardCopyTimeoutNanoseconds: UInt64 = 500_000_000
    static let audioCacheMaxEntries = 20
    /// Size cap for the on-disk audio cache (Application Support/SoundsRight/AudioCache).
    static let audioCacheDiskMaxBytes = 50 * 1024 * 1024
    static let defaultVoice = TTSVoice.avaNeural
    /// Entry cap for the in-memory translation and dictionary result caches.
    static let lookupCacheMaxEntries = 200
    /// How many automatic history entries to keep (menu bar → Recent).
    static let recentLookupsMaxEntries = 20
    /// How many recent lookups the menu bar dropdown shows.
    static let recentLookupsMenuLimit = 4
    /// How long a transient toast stays on screen before fading out.
    static let toastDisplayDuration: TimeInterval = 1.6
    /// Hover trigger: minimum mouse-drag distance (pt) for a mouse-up to be
    /// treated as a text-selection drag rather than a plain click.
    static let hoverSelectionDragThreshold: CGFloat = 6
    /// Hover trigger: how long the pointer must rest before the lookup fires.
    static let hoverDwellSeconds: TimeInterval = 0.7
    /// Hover trigger: pointer drift (pt) still counted as "resting" while the
    /// dwell timer runs.
    static let hoverPointerTolerance: CGFloat = 8
    /// Hover trigger: how long after a selection gesture a pointer rest can
    /// still fire the lookup before the gesture expires.
    static let hoverArmWindowSeconds: TimeInterval = 4
    /// Hover trigger: how often the pointer is sampled while a gesture is armed.
    static let hoverPollIntervalNanoseconds: UInt64 = 100_000_000
    /// Distributed notification tccd posts when the accessibility trust table
    /// changes — the live signal that the user just granted/revoked access.
    static let accessibilityTrustChangedNotification = "com.apple.accessibility.api"
}
