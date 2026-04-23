import SwiftUI

struct CollectionWindowView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: CollectionStore

    @State private var selectedID: UUID?

    init(appState: AppState) {
        self.appState = appState
        self.store = appState.collectionStore
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .onAppear {
            if selectedID == nil {
                selectedID = store.items.first?.id
            }
        }
        .onChange(of: store.items, perform: { newItems in
            if let id = selectedID, !newItems.contains(where: { $0.id == id }) {
                selectedID = newItems.first?.id
            } else if selectedID == nil {
                selectedID = newItems.first?.id
            }
        })
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            List(selection: $selectedID) {
                ForEach(store.items) { item in
                    CollectionRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.remove(id: item.id)
                            }
                        }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { store.items[$0].id }
                    store.removeAll(ids: Set(ids))
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Save words and phrases from the translation panel to see them here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let item = store.items.first(where: { $0.id == id }) {
            CollectionDetailPane(appState: appState, item: item)
                .id(item.id)
        } else {
            Text(store.items.isEmpty ? "" : "Select an item to review.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row

private struct CollectionRow: View {
    let item: CollectionItem

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch item.content {
        case .word: return "character.book.closed"
        case .phrase: return "text.bubble"
        }
    }
}

// MARK: - Detail pane

private struct CollectionDetailPane: View {
    @ObservedObject var appState: AppState
    let item: CollectionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            playRow

            Color.primary.opacity(0.07).frame(height: 1)

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var playRow: some View {
        HStack(spacing: 10) {
            if case .loading = appState.ttsState {
                ProgressView().controlSize(.small).frame(width: 22, height: 22)
            } else if case .error = appState.ttsState {
                Button(action: play) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Error — tap to retry")
            } else {
                Button(action: play) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")
            }

            Button(action: { appState.cycleSpeed() }) {
                Text(appState.playbackRate.displayLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Change speed")

            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .word:
            if let dict = item.toDictionaryResult {
                DictionaryDetailView(result: dict)
            }
        case .phrase(let translation):
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.sourceText)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Text(translation)
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var isPlaying: Bool {
        if case .playing = appState.ttsState { return true }
        return false
    }

    private func play() {
        switch appState.ttsState {
        case .playing:
            appState.pauseTTS()
        case .paused:
            appState.resumeTTS()
        default:
            Task { await appState.playCollectionItem(text: item.sourceText) }
        }
    }
}
