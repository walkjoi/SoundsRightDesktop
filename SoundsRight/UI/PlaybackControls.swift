import SwiftUI

struct PlaybackControls: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {

            // Play / Pause
            if case .loading = appState.ttsState {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else if case .error = appState.ttsState {
                Button(action: playAction) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Error — tap to retry")
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

            // Loop
            Button(action: { appState.toggleLoop() }) {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.isLooping ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        appState.isLooping ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoopDisabled)
            .help(appState.isLooping ? "Stop looping" : "Loop")

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
        }
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
        if case .playing = appState.ttsState {
            appState.stopTTS()
        } else {
            Task { await appState.playTTS() }
        }
    }
}

#Preview {
    let s = AppState()
    s.currentText = "Hello"
    return PlaybackControls(appState: s)
        .padding()
        .frame(width: 420)
}
