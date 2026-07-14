import SwiftUI

/// Flashcard-style pass over the collection: items come up shuffled, audio
/// plays first, the Chinese stays hidden until revealed — listen, recall,
/// check. Entered from the Collection window's toolbar.
struct ReviewSessionView: View {
    @ObservedObject var appState: AppState
    let onDone: () -> Void

    @State private var deck: [CollectionItem]
    @State private var position = 0
    @State private var isRevealed = false

    init(appState: AppState, items: [CollectionItem], onDone: @escaping () -> Void) {
        self.appState = appState
        self.onDone = onDone
        _deck = State(initialValue: items.shuffled())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider()

            if let item = currentItem {
                card(for: item)
            } else {
                roundComplete
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { playCurrent() }
    }

    private var currentItem: CollectionItem? {
        deck.indices.contains(position) ? deck[position] : nil
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(currentItem == nil
                 ? "Review"
                 : "Reviewing \(position + 1) of \(deck.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("End Review") {
                onDone()
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Card

    private func card(for item: CollectionItem) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)

            Text(item.sourceText)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 32)

            playButton(for: item)

            Group {
                if isRevealed {
                    revealedContent(for: item)
                } else {
                    Button("Reveal") {
                        isRevealed = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 120, alignment: .top)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(position == deck.count - 1 ? "Finish" : "Next") {
                    advance()
                }
                // Return reveals first, then advances — the study rhythm.
                .keyboardShortcut(isRevealed ? .defaultAction : nil)
                .controlSize(.large)
                Spacer()
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func playButton(for item: CollectionItem) -> some View {
        if case .loading = appState.ttsState {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        } else {
            Button {
                appState.playCollectionItem(text: item.sourceText)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Play again")
        }
    }

    @ViewBuilder
    private func revealedContent(for item: CollectionItem) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            switch item.content {
            case .word:
                if let dictionary = item.toDictionaryResult {
                    DictionaryDetailView(result: dictionary)
                        .padding(.horizontal, 24)
                }
            case .phrase(let translation):
                Text(translation)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Round Complete

    private var roundComplete: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)

            Text("Round complete")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text("You reviewed \(deck.count) item\(deck.count == 1 ? "" : "s").")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Review Again") {
                    deck.shuffle()
                    position = 0
                    isRevealed = false
                    playCurrent()
                }
                .keyboardShortcut(.defaultAction)

                Button("Done") {
                    onDone()
                }
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Flow

    private func advance() {
        isRevealed = false
        position += 1
        playCurrent()
    }

    private func playCurrent() {
        guard let item = currentItem else { return }
        appState.playCollectionItem(text: item.sourceText)
    }
}
