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
                // Original text — secondary, context only, scrollable when long
                ScrollView(.vertical, showsIndicators: false) {
                    Text(appState.currentText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 60)
            }

            // Playback controls — clearly under the English text
            PlaybackControls(appState: appState)

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
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dictionaryResult.word)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    if !dictionaryResult.phonetics.isEmpty {
                        Text(dictionaryResult.phonetics.joined(separator: "  "))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if appState.isTranslatingDefinitions {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Translating definitions…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(dictionaryResult.meanings) { meaning in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(meaning.partOfSpeech.capitalized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .textCase(.uppercase)

                                    Text(meaning.definition)
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    if let translated = meaning.translatedDefinition {
                                        Text(translated)
                                            .font(.system(size: 14, weight: .regular, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                Text(appState.translation?.translated ?? "")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .translationTask(config) { session in
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
            .translationTask(config) { session in
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

#Preview {
    let s = AppState()
    s.currentText = "The quick brown fox jumps over the lazy dog."
    s.translation = TranslationResult(translated: "快速的棕色狐狸跳过了懒狗")
    return TranslationView(appState: s)
}
