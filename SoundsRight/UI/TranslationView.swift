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
            self.modifier(TranslationSessionModifier(appState: appState))
        } else {
            self
        }
    }
}

/// Hosts the app's single Apple Translation session — en → zh-Hans serves both
/// sentence translation and dictionary-definition batches. The task closure
/// stays resident, looping over a work stream from AppState, so the session
/// (and its loaded language models) survives across lookups instead of being
/// rebuilt on every activation. If the loop is ever torn down, the next
/// trigger re-arms it by invalidating the configuration.
@available(macOS 15.0, *)
private struct TranslationSessionModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .task {
                // Covers work enqueued before this view first rendered — an
                // onChange for that trigger bump never fires.
                if appState.hasPendingTranslationWork {
                    armSessionIfNeeded()
                }
            }
            .onChange(of: appState.translationWorkTrigger) {
                armSessionIfNeeded()
            }
            // The session must be used only inside this closure (it is not
            // Sendable), so all translate calls stay inline here — work is
            // skipped when superseded rather than handed elsewhere.
            .translationTask(config) { @Sendable session in
                let stream = await MainActor.run { appState.beginTranslationWorkStream() }
                for await work in stream {
                    switch work {
                    case .sentence(let pending):
                        guard await MainActor.run(body: { appState.currentRequestID == pending.requestID }) else { continue }
                        do {
                            let response = try await session.translate(pending.text)
                            await MainActor.run { appState.didFinishTranslation(response.targetText, requestID: pending.requestID) }
                        } catch {
                            await MainActor.run { appState.didFailTranslation(error, requestID: pending.requestID) }
                        }

                    case .dictionaryDefinitions(let pending):
                        guard await MainActor.run(body: { appState.currentRequestID == pending.requestID }) else { continue }
                        do {
                            // One batched call — the framework parallelizes
                            // internally and returns responses in request order.
                            let responses = try await session.translations(
                                from: pending.result.meanings.map { TranslationSession.Request(sourceText: $0.definition) }
                            )
                            let result = Self.translatedResult(from: responses, for: pending.result)
                            await MainActor.run { appState.didFinishDictionaryTranslation(result, requestID: pending.requestID) }
                        } catch {
                            await MainActor.run {
                                appState.didFailDictionaryTranslation(fallback: pending.result, error: error, requestID: pending.requestID)
                            }
                        }
                    }
                }
            }
    }

    /// (Re)starts the session task. A live loop consumes new work straight
    /// from the stream, so this only acts when none is running.
    private func armSessionIfNeeded() {
        guard !appState.hasLiveTranslationSession else { return }
        if config == nil {
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
        } else {
            config?.invalidate()
        }
    }

    /// Merges batch responses back into the dictionary entry, definition by
    /// definition (responses arrive in request order).
    private nonisolated static func translatedResult(
        from responses: [TranslationSession.Response],
        for dictResult: DictionaryResult
    ) -> DictionaryResult {
        let translatedMeanings = zip(dictResult.meanings, responses).map { meaning, response in
            DictionaryMeaning(
                partOfSpeech: meaning.partOfSpeech,
                definition: meaning.definition,
                translatedDefinition: response.targetText
            )
        }
        return DictionaryResult(
            word: dictResult.word,
            phonetics: dictResult.phonetics,
            meanings: translatedMeanings
        )
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
