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

enum AppConstants {
    static let claudeAPIURL = "https://api.anthropic.com/v1/messages"
    static let claudeModel = "claude-sonnet-4-6"
    static let claudeAPIVersion = "2023-06-01"
    static let dictionaryAPIBaseURL = "https://api.dictionaryapi.dev/api/v2/entries/en/"
    static let edgeTTSEndpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    static let maxInputLength = 1000
    static let audioCacheMaxEntries = 20
    static let keychainService = "SoundsRightDesktop"
    static let defaultVoice = TTSVoice.avaNeural
}
