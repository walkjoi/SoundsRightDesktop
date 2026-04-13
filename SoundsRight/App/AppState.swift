import SwiftUI
import os

enum TTSPlaybackState {
    case idle
    case loading
    case playing
    case paused
    case finished
    case error(String)

    var isPlayingOrLoading: Bool {
        switch self {
        case .loading, .playing:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var currentText: String = ""
    @Published var translation: TranslationResult?
    @Published var isTranslating: Bool = false
    @Published var translationError: String?

    @Published var ttsState: TTSPlaybackState = .idle
    @Published var lastError: String?
    @Published var isLooping: Bool = false

    @Published var isPanelVisible: Bool = false

    var hasAudioData: Bool { audioPlayer.hasAudioData }

    /// Incrementing this triggers the translation task in TranslationView (Apple Translation Framework)
    @Published var translationTrigger: Int = 0

    // MARK: - App Storage

    @AppStorage("autoPlay") var autoPlay: Bool = true
    @AppStorage("playbackRate") var playbackRateRaw: Double = 1.0
    var playbackRate: PlaybackRate {
        PlaybackRate(rawValue: playbackRateRaw) ?? .normal
    }

    // MARK: - Services

    private let ttsManager = TTSManager()
    let audioPlayer = AudioPlayer()
    let shortcutManager = ShortcutManager()

    // MARK: - Panel Management

    private var floatingPanel: FloatingPanel?
    private var soundOnlyPanel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var isInitialized = false
    private var lastActivationMode: ActivationMode = .translation
    private var hideSoundOnlyTask: Task<Void, Never>?

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "AppState")

    // MARK: - Initialization

    init() {
        logger.debug("AppState initialized")
    }

    deinit {
        logger.debug("AppState deallocated")
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

        logger.info("Initializing app state")

        SelectionReader.ensureAccessibilityPermission()

        await ttsManager.initialize()
        logger.info("TTS manager initialized")

        // Update ttsState when audio finishes playing naturally
        audioPlayer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .playing = self.ttsState {
                    self.ttsState = .finished
                    if self.lastActivationMode == .soundOnly && !self.isLooping {
                        self.hideSoundOnlyHUD()
                    }
                }
            }
        }

        shortcutManager.register(
            onTranslate: { [weak self] in
                Task { @MainActor in
                    await self?.activate(mode: .translation)
                }
            },
            onSoundOnly: { [weak self] in
                Task { @MainActor in
                    await self?.activate(mode: .soundOnly)
                }
            }
        )

        logger.info("Keyboard shortcuts registered")
    }

    func shutdown() async {
        logger.info("Shutting down app")
        shortcutManager.unregister()
        audioPlayer.stop()
        await ttsManager.shutdown()
        hidePanel()
        soundOnlyPanel?.orderOut(nil)
        logger.info("App shutdown complete")
    }

    // MARK: - Core Actions

    @MainActor
    func activate(mode: ActivationMode) async {
        logger.info("Activate triggered with mode: \(mode.rawValue)")
        lastActivationMode = mode

        // Clean up any active state from the previous activation
        isLooping = false
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        audioPlayer.reset()
        floatingPanel?.orderOut(nil)
        isPanelVisible = false
        soundOnlyPanel?.orderOut(nil)

        guard let selectedText = await SelectionReader.readSelectedText() else {
            logger.info("No text selected — ignoring activation")
            return
        }

        currentText = selectedText
        translation = nil
        translationError = nil
        ttsState = .idle

        switch mode {
        case .translation:
            showPanel()
            async let translationTask: Void = startTranslation()
            if autoPlay {
                async let playbackTask: Void = playTTS()
                _ = await (translationTask, playbackTask)
            } else {
                await translationTask
            }
        case .soundOnly:
            showSoundOnlyHUD()
            await playTTS()
        }
    }

    // MARK: - Translation

    private func startTranslation() async {
        guard !currentText.isEmpty else { return }

        if #available(macOS 15, *) {
            // Kick off the translation task in TranslationView by incrementing the trigger.
            isTranslating = true
            translationError = nil
            translation = nil
            translationTrigger += 1
        } else {
            translationError = "Translation requires macOS 15 (Sequoia) or later."
        }
    }

    /// Called by TranslationView when Apple Translation succeeds.
    func didFinishTranslation(_ text: String) {
        translation = TranslationResult(translated: text)
        isTranslating = false
        translationError = nil
        logger.info("Translation succeeded")
    }

    /// Called by TranslationView when Apple Translation fails.
    func didFailTranslation(_ error: Error) {
        translationError = error.localizedDescription
        isTranslating = false
        logger.error("Translation failed: \(error.localizedDescription)")
    }

    // MARK: - TTS Playback

    func playTTS() async {
        logger.info("Starting TTS playback")
        isLooping = false
        ttsState = .loading
        lastError = nil

        let result = await ttsManager.synthesize(text: currentText, rate: playbackRate)

        switch result {
        case .audioData(let audioData):
            do {
                try audioPlayer.play(data: audioData)
                ttsState = .playing
                logger.info("Audio playback started")
            } catch {
                ttsState = .error(error.localizedDescription)
                lastError = error.localizedDescription
                logger.error("Failed to play audio: \(error.localizedDescription)")
            }

        case .fallbackUsed:
            ttsState = .finished
            logger.info("Fallback TTS played successfully")

        case .failed(let error):
            ttsState = .error(error.localizedDescription)
            lastError = error.localizedDescription
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
        }
    }

    func pauseTTS() {
        logger.info("Pausing TTS playback")
        audioPlayer.pause()
        ttsState = .paused
    }

    func resumeTTS() {
        logger.info("Resuming TTS playback")
        audioPlayer.resume()
        ttsState = .playing
    }

    func togglePlayPause() {
        logger.info("Toggling play/pause")
        switch ttsState {
        case .playing:
            pauseTTS()
        case .paused:
            resumeTTS()
        case .idle, .finished:
            Task {
                await playTTS()
            }
        case .loading, .error:
            return
        }
    }

    func stopTTS() {
        logger.info("Stopping TTS playback")
        isLooping = false
        audioPlayer.stop()
        ttsState = .idle
    }

    func toggleLoop() {
        if isLooping {
            logger.info("Stopping loop")
            isLooping = false
            audioPlayer.stop()
            ttsState = .idle
        } else {
            logger.info("Starting loop")
            do {
                try audioPlayer.replayLooping()
                isLooping = true
                ttsState = .playing
            } catch {
                ttsState = .error(error.localizedDescription)
                lastError = error.localizedDescription
                logger.error("Loop failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Speed Control

    func cycleSpeed() {
        let newRate = playbackRate.next()
        playbackRateRaw = newRate.rawValue
        logger.info("Playback rate changed to \(newRate.displayLabel)")

        if case .playing = ttsState {
            audioPlayer.setRate(Float(newRate.rawValue))
        }
    }

    // MARK: - Panel Management

    private func showPanel() {
        logger.debug("Showing floating panel")

        if floatingPanel == nil {
            let panel = FloatingPanel()
            panel.onClose = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.stopTTS()
                }
            }
            floatingPanel = panel
        }

        guard let panel = floatingPanel else {
            logger.error("Failed to create floating panel")
            return
        }

        isPanelVisible = true

        DispatchQueue.main.async {
            let panelContent = TranslationView(appState: self)
            panel.contentView = NSHostingView(rootView: panelContent)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func hidePanel() {
        logger.debug("Hiding floating panel")
        floatingPanel?.orderOut(nil)
        isPanelVisible = false
    }

    func dismiss() {
        logger.info("Dismissing panel and stopping playback")
        stopTTS()
        hidePanel()
    }

    // MARK: - Sound Only HUD

    private func showSoundOnlyHUD() {
        if soundOnlyPanel == nil {
            let panel = FloatingPanel(contentSize: NSSize(width: 180, height: 40), borderless: true)
            panel.onClose = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.stopTTS()
                }
            }
            soundOnlyPanel = panel
        }

        guard let panel = soundOnlyPanel else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hostingView = NSHostingView(rootView: SoundOnlyHUD(appState: self))
            panel.contentView = hostingView
            let size = hostingView.fittingSize
            panel.setContentSize(size)

            // Position below-right of the cursor, clamped to screen's visible area
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 8)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
                origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
            }
            panel.setFrameOrigin(origin)
            panel.orderFront(nil)
        }
    }

    /// Called by the HUD's dismiss button.
    func dismissSoundOnlyHUD() {
        logger.info("Dismissing sound only HUD")
        stopTTS()
        soundOnlyPanel?.orderOut(nil)
    }

    /// Called automatically when audio finishes in sound-only mode.
    private func hideSoundOnlyHUD() {
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.soundOnlyPanel?.orderOut(nil)
        }
    }

    // MARK: - Settings Window

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: SettingsView(appState: self))
            window.level = .floating
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// NOTE: FloatingPanel is defined in UI/FloatingPanel.swift
// NOTE: TranslationView is defined in UI/TranslationView.swift
