import AVFoundation
import Combine
import os

/// `@MainActor` because every caller (AppState, the SwiftUI views) already lives on the
/// main actor, while AVFoundation delivers delegate callbacks on an undocumented thread —
/// the `nonisolated` delegate methods hop back in before touching state.
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentProgress: Double = 0.0

    var onFinished: (() -> Void)?

    var hasAudioData: Bool { lastAudioData != nil }

    /// Seconds into the current audio; 0 when nothing is loaded. Wraps back to
    /// the start on looped playback, which read-along tracking relies on.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var lastAudioData: Data?
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "AudioPlayer")

    func play(data: Data, loop: Bool = false) throws {
        stop()

        lastAudioData = data

        player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        guard let player = player else {
            throw AudioPlayerError.playerInitializationFailed
        }

        player.delegate = self
        player.numberOfLoops = loop ? -1 : 0
        player.prepareToPlay()

        let playSuccess = player.play()
        guard playSuccess else {
            throw AudioPlayerError.playbackFailed
        }

        isPlaying = true
        startProgressTimer()
    }

    /// Applies a loop-mode change to the loaded player in place: enabling keeps
    /// playback repeating from wherever it is; disabling lets the current pass
    /// play out and finish naturally.
    func setLooping(_ loop: Bool) {
        player?.numberOfLoops = loop ? -1 : 0
    }

    func replayLooping() throws {
        guard let audioData = lastAudioData else {
            throw AudioPlayerError.noAudioDataToReplay
        }
        try play(data: audioData, loop: true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        guard let player = player, !player.isPlaying else { return }
        let resumeSuccess = player.play()
        if resumeSuccess {
            isPlaying = true
            startProgressTimer()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentProgress = 0.0
        stopProgressTimer()
    }

    /// Stops playback and clears cached audio data so stale audio cannot be replayed.
    func reset() {
        stop()
        lastAudioData = nil
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if player != nil {
            resume()
        }
    }

    func replay() throws {
        guard let audioData = lastAudioData else {
            throw AudioPlayerError.noAudioDataToReplay
        }
        try play(data: audioData)
    }

    private func startProgressTimer() {
        stopProgressTimer()

        // Timer fires on the main run loop, so assuming main-actor isolation is safe.
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.currentProgress = player.currentTime / player.duration
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentProgress = 0.0
            self.stopProgressTimer()
            self.onFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentProgress = 0.0
            self.stopProgressTimer()
            if let error {
                self.logger.error("Audio decoding error: \(error.localizedDescription)")
            }
        }
    }
}

enum AudioPlayerError: LocalizedError {
    case playerInitializationFailed
    case playbackFailed
    case noAudioDataToReplay

    var errorDescription: String? {
        switch self {
        case .playerInitializationFailed:
            return "Failed to initialize audio player"
        case .playbackFailed:
            return "Failed to start playback"
        case .noAudioDataToReplay:
            return "No audio data available to replay"
        }
    }
}
