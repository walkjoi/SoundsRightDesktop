import AVFoundation
import Combine

class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentProgress: Double = 0.0

    var onFinished: (() -> Void)?

    var hasAudioData: Bool { lastAudioData != nil }

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var lastAudioData: Data?

    override init() {
        super.init()
    }

    deinit {
        stopProgressTimer()
    }

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

    func setRate(_ rate: Float) {
        guard let player = player else { return }
        player.enableRate = true
        player.rate = rate
    }

    private func startProgressTimer() {
        stopProgressTimer()

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let player = self.player, player.duration > 0 else { return }
                self.currentProgress = Double(player.currentTime) / Double(player.duration)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentProgress = 0.0
        stopProgressTimer()
        onFinished?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        isPlaying = false
        currentProgress = 0.0
        stopProgressTimer()
        if let error = error {
            print("Audio decoding error: \(error)")
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
