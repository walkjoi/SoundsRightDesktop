import Foundation

enum TTSVoice: String, CaseIterable {
    case avaNeural = "en-US-AvaNeural"
    case emmaMultilingualNeural = "en-US-EmmaMultilingualNeural"

    var displayName: String {
        switch self {
        case .avaNeural:
            return "Ava"
        case .emmaMultilingualNeural:
            return "Emma"
        }
    }
}

enum PlaybackRate: Double, CaseIterable, Comparable {
    case slow = 0.5
    case moderate = 0.75
    case normal = 1.0
    case fast = 1.25

    var ssmlRate: String {
        switch self {
        case .slow:
            return "-50%"
        case .moderate:
            return "-25%"
        case .normal:
            return "+0%"
        case .fast:
            return "+25%"
        }
    }

    var kokoroSpeed: Double {
        self.rawValue
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
        }
    }

    func next() -> PlaybackRate {
        switch self {
        case .slow:
            return .moderate
        case .moderate:
            return .normal
        case .normal:
            return .fast
        case .fast:
            return .slow
        }
    }

    static func < (lhs: PlaybackRate, rhs: PlaybackRate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AppConstants {
    static let claudeAPIURL = "https://api.anthropic.com/v1/messages"
    static let claudeModel = "claude-sonnet-4-6"
    static let claudeAPIVersion = "2023-06-01"
    static let edgeTTSEndpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    static let kokoroServerURL = "http://127.0.0.1:18923/tts"
    static let maxInputLength = 1000
    static let audioCacheMaxEntries = 20
    static let keychainService = "SoundsRightDesktop"
    static let defaultVoice = TTSVoice.avaNeural
}
