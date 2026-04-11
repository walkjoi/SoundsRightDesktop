import Foundation

struct TranslationResult: Sendable {
    let translated: String
}

enum TranslationError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Translation requires macOS 14 (Sonoma) or later."
        case .failed(let message):
            return message
        }
    }
}
