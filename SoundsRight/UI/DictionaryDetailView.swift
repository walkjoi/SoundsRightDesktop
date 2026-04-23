import SwiftUI

/// Renders a `DictionaryResult` (word + phonetics + meanings).
/// Shared by the floating translation panel and the collection review window.
struct DictionaryDetailView: View {
    let result: DictionaryResult
    var isTranslatingDefinitions: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.word)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if !result.phonetics.isEmpty {
                    Text(result.phonetics.joined(separator: "  "))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isTranslatingDefinitions {
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
                        ForEach(result.meanings) { meaning in
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
    }
}
