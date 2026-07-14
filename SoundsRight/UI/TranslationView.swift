import SwiftUI
import Translation

struct TranslationView: View {
    @ObservedObject var appState: AppState

    private var isSingleWordSelection: Bool {
        appState.currentText.split(whereSeparator: \.isWhitespace).count == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isSingleWordSelection {
                // Original text — secondary, context only, scrollable when long.
                // The word currently being spoken is highlighted (read-along).
                ScrollView(.vertical, showsIndicators: false) {
                    Text(highlightedSourceText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 60)
            }

            // Playback controls — clearly under the English text
            PlaybackControls(appState: appState)

            if appState.wasInputTruncated {
                Label(
                    "Reading the first \(AppConstants.maxInputLength) characters of your selection",
                    systemImage: "scissors"
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            // Separator
            Color.primary.opacity(0.07)
                .frame(height: 1)

            // Translation — the hero content, scrollable when long
            translationArea
                .frame(minHeight: 32, alignment: .topLeading)
                .animation(.easeInOut(duration: 0.15), value: appState.isTranslating)
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 560)
        .appleTranslationTask(appState: appState)
        .dictionaryTranslationTask(appState: appState)
    }

    /// The source text with the currently spoken word emphasized. Words are
    /// mapped positionally: the nth Edge word boundary highlights the nth
    /// whitespace-separated token; a mismatch simply drops the highlight.
    private var highlightedSourceText: AttributedString {
        let text = appState.currentText
        guard let wordIndex = appState.spokenWordIndex,
              let range = Self.wordRange(in: text, wordIndex: wordIndex)
        else {
            return AttributedString(text)
        }

        let before = AttributedString(String(text[text.startIndex..<range.lowerBound]))
        var spoken = AttributedString(String(text[range]))
        spoken.backgroundColor = Color.accentColor.opacity(0.22)
        spoken.foregroundColor = Color.primary
        let after = AttributedString(String(text[range.upperBound...]))
        return before + spoken + after
    }

    /// Range of the nth whitespace-separated token of `text`.
    private static func wordRange(in text: String, wordIndex: Int) -> Range<String.Index>? {
        var tokenIndex = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { return nil }
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            if tokenIndex == wordIndex {
                return start..<cursor
            }
            tokenIndex += 1
        }
        return nil
    }

    @ViewBuilder
    private var translationArea: some View {
        if let error = appState.translationError, !error.isEmpty {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if appState.isTranslating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(appState.currentText.contains(where: \.isWhitespace) ? "Translating…" : "Looking up word…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        } else if let dictionaryResult = appState.dictionaryResult {
            ScrollView(.vertical, showsIndicators: false) {
                DictionaryDetailView(
                    result: dictionaryResult,
                    isTranslatingDefinitions: appState.isTranslatingDefinitions
                )
            }
            .frame(maxHeight: 260)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                Text(appState.translation?.translated ?? "")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Full wrapped height, so the panel's fit-to-content resize
                    // measures every line instead of a collapsed scroll view.
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
    }
}

// MARK: - Apple Translation

private extension View {
    @ViewBuilder
    func appleTranslationTask(appState: AppState) -> some View {
        if #available(macOS 15, *) {
            self.modifier(AppleTranslationModifier(appState: appState))
        } else {
            self
        }
    }

    @ViewBuilder
    func dictionaryTranslationTask(appState: AppState) -> some View {
        if #available(macOS 15, *) {
            self.modifier(DictionaryTranslationModifier(appState: appState))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.translationTrigger) {
                config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans")
                )
            }
            .translationTask(config) { @Sendable session in
                let pending = await MainActor.run { appState.pendingTranslation }
                guard let pending else { return }
                do {
                    let response = try await session.translate(pending.text)
                    await MainActor.run { appState.didFinishTranslation(response.targetText, requestID: pending.requestID) }
                } catch {
                    await MainActor.run { appState.didFailTranslation(error, requestID: pending.requestID) }
                }
            }
    }
}

@available(macOS 15.0, *)
private struct DictionaryTranslationModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.dictionaryTranslationTrigger) {
                config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans")
                )
            }
            .translationTask(config) { @Sendable session in
                let pending = await MainActor.run { appState.pendingDictionaryResult }
                guard let pending else { return }
                let requestID = pending.requestID
                let dictResult = pending.result
                do {
                    var translations: [String] = []
                    translations.reserveCapacity(dictResult.meanings.count)
                    for meaning in dictResult.meanings {
                        let response = try await session.translate(meaning.definition)
                        translations.append(response.targetText)
                    }
                    let translatedMeanings = zip(dictResult.meanings, translations).map { meaning, translated in
                        DictionaryMeaning(
                            partOfSpeech: meaning.partOfSpeech,
                            definition: meaning.definition,
                            translatedDefinition: translated
                        )
                    }
                    let result = DictionaryResult(
                        word: dictResult.word,
                        phonetics: dictResult.phonetics,
                        meanings: translatedMeanings
                    )
                    await MainActor.run { appState.didFinishDictionaryTranslation(result, requestID: requestID) }
                } catch {
                    await MainActor.run { appState.didFailDictionaryTranslation(fallback: dictResult, error: error, requestID: requestID) }
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let s = AppState()
    s.currentText = "The quick brown fox jumps over the lazy dog."
    s.translation = TranslationResult(translated: "快速的棕色狐狸跳过了懒狗")
    return TranslationView(appState: s)
}
#endif
