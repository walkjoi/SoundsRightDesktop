import SwiftUI

struct PlaybackControls: View {
    @ObservedObject var appState: AppState
    @ObservedObject var collectionStore: CollectionStore

    init(appState: AppState) {
        self.appState = appState
        self.collectionStore = appState.collectionStore
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {

            // Play / Pause
            if case .loading = appState.ttsState {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else if case .error(let message) = appState.ttsState {
                Button(action: playAction) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("\(message) — tap to retry")
            } else {
                Button(action: playAction) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(appState.currentText.isEmpty)
                .help(isPlaying ? "Pause" : "Play")
            }

            // Repeat (persistent preference, shared with the HUD)
            Button(action: { appState.toggleLoop() }) {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.repeatEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        appState.repeatEnabled ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoopDisabled)
            .help(appState.repeatEnabled ? "Turn off repeat" : "Repeat")

            // Speed pill
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

            if appState.isUsingFallbackVoice {
                OfflineVoiceBadge()
            }

            Spacer(minLength: 0)

            // Copy translation
            Button(action: { appState.copyTranslationToClipboard() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!appState.canCopyTranslation)
            .help("Copy translation (C)")

            // Save to collection
            Button(action: { appState.toggleSaveCurrentToCollection() }) {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSaved ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        isSaved ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!appState.canSaveCurrentToCollection && !isSaved)
            .help(isSaved ? "Remove from collection (S)" : "Save to collection (S)")

            // Pin: keeps the panel up (clicks outside no longer dismiss it)
            Button(action: { appState.togglePanelPin() }) {
                Image(systemName: appState.isPanelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.isPanelPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        appState.isPanelPinned ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .help(appState.isPanelPinned ? "Unpin — click outside to dismiss" : "Pin panel")
        }
    }

    private var isSaved: Bool {
        appState.isCurrentSavedInCollection
    }

    private var isPlaying: Bool {
        if case .playing = appState.ttsState { return true }
        return false
    }

    private var isLoopDisabled: Bool {
        if case .loading = appState.ttsState { return true }
        return !appState.hasAudioData
    }

    private func playAction() {
        appState.togglePlayPause()
    }
}

/// Explains the audible quality drop when the AVSpeech fallback is speaking
/// (and why loop/replay are unavailable — fallback speech has no audio data).
struct OfflineVoiceBadge: View {
    var body: some View {
        Text("Offline voice")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .help("The online voice couldn't be reached — using the built-in macOS voice. Loop and replay are unavailable.")
    }
}

#if DEBUG
#Preview {
    let s = AppState()
    s.currentText = "Hello"
    return PlaybackControls(appState: s)
        .padding()
        .frame(width: 420)
}
#endif
