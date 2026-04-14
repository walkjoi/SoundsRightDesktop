import Foundation

actor TranslationService {
    func dictionaryLookupCandidate(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(whereSeparator: \.isWhitespace)
        guard components.count == 1, let token = components.first else { return nil }

        let candidate = token.trimmingCharacters(in: .punctuationCharacters)
        guard !candidate.isEmpty else { return nil }
        return candidate
    }

    func lookupDictionaryEntry(for word: String) async throws -> DictionaryResult {
        guard
            let encodedWord = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: AppConstants.dictionaryAPIBaseURL + encodedWord)
        else {
            throw TranslationError.failed("Failed to prepare dictionary lookup.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.failed("Dictionary lookup returned an invalid response.")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            throw TranslationError.failed("No dictionary entry found for \"\(word)\".")
        default:
            throw TranslationError.failed("Dictionary lookup failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode([DictionaryAPIEntry].self, from: data)
        guard let entry = decoded.first else {
            throw TranslationError.failed("No dictionary entry found for \"\(word)\".")
        }

        let rawPhonetics: [String] = ([entry.phonetic].compactMap { $0 } + entry.phonetics.compactMap(\.text))
            .compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        let phonetics = Array(Set(rawPhonetics)).sorted()

        let meanings: [DictionaryMeaning] = entry.meanings.flatMap { meaning in
            meaning.definitions.compactMap { definition -> DictionaryMeaning? in
                let trimmed = definition.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return DictionaryMeaning(partOfSpeech: meaning.partOfSpeech, definition: trimmed)
            }
        }

        guard !meanings.isEmpty else {
            throw TranslationError.failed("No definitions available for \"\(word)\".")
        }

        return DictionaryResult(
            word: entry.word.isEmpty ? word : entry.word,
            phonetics: phonetics,
            meanings: meanings
        )
    }
}

private struct DictionaryAPIEntry: Decodable {
    let word: String
    let phonetic: String?
    let phonetics: [DictionaryAPIPhonetic]
    let meanings: [DictionaryAPIMeaning]
}

private struct DictionaryAPIPhonetic: Decodable {
    let text: String?
}

private struct DictionaryAPIMeaning: Decodable {
    let partOfSpeech: String
    let definitions: [DictionaryAPIDefinition]
}

private struct DictionaryAPIDefinition: Decodable {
    let definition: String
}
