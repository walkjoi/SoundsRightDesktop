import Foundation

struct TranslationResult: Sendable {
    let translated: String
}

struct DictionaryResult: Sendable {
    let word: String
    let phonetics: [String]
    let meanings: [DictionaryMeaning]
}

struct DictionaryMeaning: Sendable, Identifiable {
    let id = UUID()
    let partOfSpeech: String
    let definition: String
}

enum TranslationError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Translation requires macOS 15 (Sequoia) or later."
        case .failed(let message):
            return message
        }
    }
}
