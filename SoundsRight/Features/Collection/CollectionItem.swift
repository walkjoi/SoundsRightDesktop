import Foundation

struct CollectionItem: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceText: String
    let createdAt: Date
    let content: Content

    enum Content: Codable, Sendable, Equatable {
        case word(phonetics: [String], meanings: [Meaning])
        case phrase(translation: String)
    }

    struct Meaning: Codable, Sendable, Equatable {
        let partOfSpeech: String
        let definition: String
        let translatedDefinition: String?
    }

    init(
        id: UUID = UUID(),
        sourceText: String,
        createdAt: Date = Date(),
        content: Content
    ) {
        self.id = id
        self.sourceText = sourceText
        self.createdAt = createdAt
        self.content = content
    }

    static func normalizedKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedKey: String {
        Self.normalizedKey(for: sourceText)
    }
}

extension CollectionItem {
    static func from(
        dictionaryResult: DictionaryResult,
        sourceText: String
    ) -> CollectionItem {
        let meanings = dictionaryResult.meanings.map { m in
            Meaning(
                partOfSpeech: m.partOfSpeech,
                definition: m.definition,
                translatedDefinition: m.translatedDefinition
            )
        }
        return CollectionItem(
            sourceText: sourceText,
            content: .word(phonetics: dictionaryResult.phonetics, meanings: meanings)
        )
    }

    static func from(
        translation: TranslationResult,
        sourceText: String
    ) -> CollectionItem {
        CollectionItem(
            sourceText: sourceText,
            content: .phrase(translation: translation.translated)
        )
    }

    var toDictionaryResult: DictionaryResult? {
        guard case .word(let phonetics, let meanings) = content else { return nil }
        return DictionaryResult(
            word: sourceText,
            phonetics: phonetics,
            meanings: meanings.map {
                DictionaryMeaning(
                    partOfSpeech: $0.partOfSpeech,
                    definition: $0.definition,
                    translatedDefinition: $0.translatedDefinition
                )
            }
        )
    }

    var phraseTranslation: String? {
        guard case .phrase(let translation) = content else { return nil }
        return translation
    }
}
