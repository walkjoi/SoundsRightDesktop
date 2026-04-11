import SwiftUI

struct SoundOnlyHUD: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {

            // Play / Pause / Loading / Error
            Group {
                if case .loading = appState.ttsState {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                } else if case .error = appState.ttsState {
                    Button(action: { Task { await appState.playTTS() } }) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Error — tap to retry")
                } else {
                    Button(action: { appState.togglePlayPause() }) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Pause" : "Play")
                }
            }

            // Loop
            Button(action: { appState.toggleLoop() }) {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.isLooping ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        appState.isLooping ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasAudioData)
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

            Divider()
                .frame(height: 16)

            // Dismiss
            Button(action: { appState.dismissSoundOnlyHUD() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 220)
    }

    private var isPlaying: Bool {
        if case .playing = appState.ttsState { return true }
        return false
    }
}

#Preview {
    let s = AppState()
    s.currentText = "Hello"
    return SoundOnlyHUD(appState: s)
}
