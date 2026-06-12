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
    @Published var dictionaryResult: DictionaryResult?
    @Published var isTranslating: Bool = false
    @Published var translationError: String?

    /// True while the Chinese translation of dictionary definitions is in flight — word + phonetics are already visible.
    @Published var isTranslatingDefinitions: Bool = false

    @Published var ttsState: TTSPlaybackState = .idle
    @Published var isLooping: Bool = false

    @Published var isPanelVisible: Bool = false

    var hasAudioData: Bool { audioPlayer.hasAudioData }

    /// Incrementing this triggers the translation task in TranslationView (Apple Translation Framework)
    @Published var translationTrigger: Int = 0

    /// Incrementing this triggers batched dictionary definition translation in TranslationView.
    @Published var dictionaryTranslationTrigger: Int = 0

    struct PendingDictionaryResult {
        let requestID: Int
        let result: DictionaryResult
    }

    struct PendingTranslation {
        let requestID: Int
        let text: String
    }

    /// English-only dictionary result awaiting Chinese translation. Internal handoff to TranslationView.
    var pendingDictionaryResult: PendingDictionaryResult?

    /// Sentence-mode text awaiting Apple Translation. Internal handoff to TranslationView.
    var pendingTranslation: PendingTranslation?

    /// Monotonic ID bumped on every activation. Async callbacks guard on this to avoid stale writes.
    private(set) var currentRequestID: Int = 0

    // MARK: - App Storage

    @AppStorage("autoPlay") var autoPlay: Bool = true
    @AppStorage("playbackRate") var playbackRateRaw: Double = 1.0
    @AppStorage("playbackRateOptions") var playbackRateOptionsRaw: String =
        PlaybackRate.storageValue(for: PlaybackRate.defaultOptions)

    var availablePlaybackRates: [PlaybackRate] {
        PlaybackRate.options(from: playbackRateOptionsRaw)
    }

    var playbackRate: PlaybackRate {
        let availableRates = availablePlaybackRates

        if let storedRate = PlaybackRate(rawValue: playbackRateRaw), availableRates.contains(storedRate) {
            return storedRate
        }

        if availableRates.contains(.normal) {
            return .normal
        }

        return availableRates.first ?? .normal
    }

    // MARK: - Services

    private let ttsManager = TTSManager()
    private let translationService = TranslationService()
    let audioPlayer = AudioPlayer()
    let shortcutManager = ShortcutManager()
    let collectionStore = CollectionStore()

    // MARK: - Panel Management

    private var floatingPanel: FloatingPanel?
    private var soundOnlyPanel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var collectionWindow: NSWindow?
    private var isInitialized = false
    private var lastActivationMode: ActivationMode = .translation
    private var hideSoundOnlyTask: Task<Void, Never>?
    private var restartPlaybackTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var isPresentingAccessibilityAlert = false

    /// Monotonic ID for playback intents (hotkey play, collection play, rate restart).
    /// Captured before `synthesize` and checked after, so a superseded synthesis
    /// cannot clobber a newer one's audio or state.
    private var playbackGeneration = 0

    /// Generation of the live AVSpeech fallback utterance, nil when playback is
    /// audio-data-backed (or idle). Lets finish/cancel events and stop requests be
    /// attributed to the exact utterance instead of a racy Bool.
    private var activeFallbackGeneration: Int?

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "AppState")

    private var isSingleWordSelection: Bool {
        currentText.split(whereSeparator: \.isWhitespace).count == 1
    }

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

        // Mirror of audioPlayer.onFinished for the AVSpeech fallback path.
        await ttsManager.setFallbackFinishedHandler { [weak self] generation, finishedNaturally in
            guard let self, generation == self.activeFallbackGeneration else { return }
            self.activeFallbackGeneration = nil
            guard finishedNaturally else { return }
            switch self.ttsState {
            // .paused as well: a pause click racing the utterance's natural finish
            // must not strand the UI in a paused state with no speech to resume.
            case .playing, .paused:
                self.ttsState = .finished
                if self.lastActivationMode == .soundOnly && !self.isLooping {
                    self.hideSoundOnlyHUD()
                }
            default:
                break
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
        await collectionStore.flush()
        hidePanel()
        soundOnlyPanel?.orderOut(nil)
        logger.info("App shutdown complete")
    }

    // MARK: - Core Actions

    @MainActor
    func activate(mode: ActivationMode) async {
        currentRequestID += 1
        let requestID = currentRequestID

        logger.info("Activate triggered with mode: \(mode.rawValue), requestID: \(requestID)")
        lastActivationMode = mode

        // Clean up any active state from the previous activation
        isLooping = false
        playbackGeneration += 1
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer.reset()
        await stopFallbackPlayback()
        floatingPanel?.orderOut(nil)
        isPanelVisible = false
        soundOnlyPanel?.orderOut(nil)

        let selectedText: String
        switch await SelectionReader.readSelectedText() {
        case .success(let text):
            selectedText = text
        case .failure(.noSelection):
            logger.info("No text selected — ignoring activation")
            return
        case .failure(.readInProgress):
            logger.info("Selection read already in progress — ignoring activation")
            return
        case .failure(.noPermission):
            logger.warning("Accessibility permission missing — prompting user")
            presentAccessibilityAlert()
            return
        case .failure(.eventCreationFailed):
            logger.error("Could not synthesize Cmd+C event — ignoring activation")
            return
        }

        guard requestID == currentRequestID else { return }

        currentText = selectedText
        translation = nil
        dictionaryResult = nil
        translationError = nil
        pendingDictionaryResult = nil
        pendingTranslation = nil
        isTranslating = false
        isTranslatingDefinitions = false
        ttsState = .idle

        switch mode {
        case .translation:
            showPanel()
            if autoPlay {
                startPlayback { await self.playTTS() }
            }
            await startTranslation(requestID: requestID)
        case .soundOnly:
            showSoundOnlyHUD()
            startPlayback { await self.playTTS() }
        }
    }

    /// Cancel-and-replace owner for playback tasks, so a new playback intent always
    /// invalidates the previous one (cancellation reaches TTSManager's fallback guard).
    private func startPlayback(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        playbackTask?.cancel()
        playbackTask = Task { await operation() }
    }

    /// Stops any AVSpeech fallback speech. Unconditional (not gated on tracked state):
    /// `FallbackTTSService.stop()` is an idempotent no-op when nothing is speaking, and an
    /// untracked orphan utterance must still be silenced.
    private func stopFallbackPlayback() async {
        activeFallbackGeneration = nil
        await ttsManager.stopPlayback()
    }

    /// Shown when a hotkey fires without the Accessibility grant the app depends on.
    private func presentAccessibilityAlert() {
        // runModal's nested run loop still drains the main queue, so repeated hotkey
        // presses would stack identical alerts without this guard.
        guard !isPresentingAccessibilityAlert else { return }
        isPresentingAccessibilityAlert = true
        defer { isPresentingAccessibilityAlert = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        SoundsRight reads the selected text by simulating Cmd+C, which needs \
        Accessibility access. Enable SoundsRight in System Settings → \
        Privacy & Security → Accessibility, then press the shortcut again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Translation

    private func startTranslation(requestID: Int) async {
        guard !currentText.isEmpty else { return }
        guard requestID == currentRequestID else { return }

        isTranslating = true
        translationError = nil
        translation = nil
        dictionaryResult = nil
        pendingDictionaryResult = nil
        pendingTranslation = nil
        isTranslatingDefinitions = false

        if let word = await translationService.dictionaryLookupCandidate(from: currentText) {
            guard requestID == currentRequestID else { return }
            do {
                let result = try await translationService.lookupDictionaryEntry(for: word)
                guard requestID == currentRequestID else { return }
                if #available(macOS 15, *) {
                    dictionaryResult = result
                    pendingDictionaryResult = PendingDictionaryResult(requestID: requestID, result: result)
                    isTranslating = false
                    isTranslatingDefinitions = true
                    dictionaryTranslationTrigger += 1
                    resizePanelToFitContent()
                } else {
                    dictionaryResult = result
                    isTranslating = false
                    resizePanelToFitContent()
                }
                logger.info("Dictionary lookup succeeded")
            } catch {
                guard requestID == currentRequestID else { return }
                logger.error("Dictionary lookup failed: \(error.localizedDescription)")
                if #available(macOS 15, *) {
                    // Word not in the dictionary (or API unavailable) — Apple Translation
                    // handles single words fine, so degrade to the sentence path.
                    logger.info("Falling back to Apple Translation for single word")
                    pendingTranslation = PendingTranslation(requestID: requestID, text: currentText)
                    translationTrigger += 1
                } else {
                    translationError = error.localizedDescription
                    isTranslating = false
                    resizePanelToFitContent()
                }
            }
            return
        }

        if #available(macOS 15, *) {
            pendingTranslation = PendingTranslation(requestID: requestID, text: currentText)
            translationTrigger += 1
        } else {
            isTranslating = false
            translationError = "Translation requires macOS 15 (Sequoia) or later."
        }
    }

    /// Called by TranslationView when Apple Translation succeeds.
    func didFinishTranslation(_ text: String, requestID: Int) {
        guard requestID == currentRequestID else { return }
        translation = TranslationResult(translated: text)
        pendingTranslation = nil
        isTranslating = false
        translationError = nil
        logger.info("Translation succeeded")
    }

    /// Called by TranslationView when Apple Translation fails.
    func didFailTranslation(_ error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        translationError = error.localizedDescription
        pendingTranslation = nil
        isTranslating = false
        logger.error("Translation failed: \(error.localizedDescription)")
    }

    /// Called by TranslationView after batched dictionary definition translation succeeds.
    func didFinishDictionaryTranslation(_ result: DictionaryResult, requestID: Int) {
        guard requestID == currentRequestID else { return }
        dictionaryResult = result
        pendingDictionaryResult = nil
        isTranslatingDefinitions = false
        resizePanelToFitContent()
        logger.info("Dictionary definitions translated")
    }

    /// Called by TranslationView when dictionary translation fails — fall back to English-only result.
    func didFailDictionaryTranslation(fallback: DictionaryResult, error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        dictionaryResult = fallback
        pendingDictionaryResult = nil
        isTranslatingDefinitions = false
        resizePanelToFitContent()
        logger.error("Dictionary translation failed, showing English-only: \(error.localizedDescription)")
    }

    // MARK: - TTS Playback

    func playTTS() async {
        logger.info("Starting TTS playback")
        playbackGeneration += 1
        let generation = playbackGeneration
        isLooping = false
        ttsState = .loading
        // Clear stale audio so loop/replay affordances stay disabled while a fresh
        // synthesis (possibly fallback speech with no data) is in flight.
        audioPlayer.reset()
        await stopFallbackPlayback()

        let result = await ttsManager.synthesize(text: currentText, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            // Superseded — if our synthesize already started fallback speech, silence
            // it (generation-scoped, so a newer utterance is never touched).
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audioData(let audioData):
            do {
                try audioPlayer.play(data: audioData)
                ttsState = .playing
                logger.info("Audio playback started")
            } catch {
                ttsState = .error(error.localizedDescription)
                logger.error("Failed to play audio: \(error.localizedDescription)")
            }

        case .fallbackUsed(let utteranceGeneration):
            activeFallbackGeneration = utteranceGeneration
            ttsState = .playing
            logger.info("Fallback TTS playback started")

        case .failed(let error):
            ttsState = .error(error.localizedDescription)
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
        }
    }

    func pauseTTS() {
        logger.info("Pausing TTS playback")
        if activeFallbackGeneration != nil {
            Task { await ttsManager.pauseFallback() }
        } else {
            audioPlayer.pause()
        }
        ttsState = .paused
    }

    func resumeTTS() {
        logger.info("Resuming TTS playback")
        if activeFallbackGeneration != nil {
            Task { await ttsManager.resumeFallback() }
        } else {
            audioPlayer.resume()
        }
        ttsState = .playing
    }

    func togglePlayPause() {
        logger.info("Toggling play/pause")
        switch ttsState {
        case .playing:
            pauseTTS()
        case .paused:
            resumeTTS()
        case .idle, .finished, .error:
            startPlayback { await self.playTTS() }
        case .loading:
            return
        }
    }

    func stopTTS() {
        logger.info("Stopping TTS playback")
        isLooping = false
        playbackGeneration += 1
        playbackTask?.cancel()
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        audioPlayer.stop()
        activeFallbackGeneration = nil
        Task { await ttsManager.stopPlayback() }
        ttsState = .idle
    }

    func toggleLoop() {
        if isLooping {
            logger.info("Stopping loop")
            isLooping = false
            audioPlayer.stop()
            ttsState = .idle
        } else {
            // Looping replays buffered audio data; fallback speech has none.
            guard activeFallbackGeneration == nil else { return }
            logger.info("Starting loop")
            do {
                try audioPlayer.replayLooping()
                isLooping = true
                ttsState = .playing
            } catch {
                ttsState = .error(error.localizedDescription)
                logger.error("Loop failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Speed Control

    func cycleSpeed() {
        let availableRates = availablePlaybackRates
        guard !availableRates.isEmpty else { return }

        let currentRate = playbackRate
        let currentIndex = availableRates.firstIndex(of: currentRate) ?? 0
        let nextIndex = availableRates.index(after: currentIndex)
        let newRate = nextIndex < availableRates.endIndex ? availableRates[nextIndex] : availableRates[availableRates.startIndex]

        setPlaybackRate(newRate)
    }

    func setPlaybackRate(_ rate: PlaybackRate) {
        let previousRate = playbackRate
        playbackRateRaw = rate.rawValue
        guard previousRate != rate else { return }

        logger.info("Playback rate changed to \(rate.displayLabel)")

        if case .playing = ttsState {
            let shouldLoop = isLooping
            restartPlaybackTask?.cancel()
            restartPlaybackTask = Task {
                await restartPlaybackForUpdatedRate(loop: shouldLoop)
            }
        }
    }

    func setPlaybackRateOptions(_ rates: [PlaybackRate]) {
        let sanitizedRates = PlaybackRate.sanitized(rates)
        let previousRate = PlaybackRate(rawValue: playbackRateRaw) ?? playbackRate
        playbackRateOptionsRaw = PlaybackRate.storageValue(for: sanitizedRates)

        if !sanitizedRates.contains(previousRate) {
            setPlaybackRate(sanitizedRates.contains(.normal) ? .normal : sanitizedRates[0])
        }
    }

    func isPlaybackRateEnabled(_ rate: PlaybackRate) -> Bool {
        availablePlaybackRates.contains(rate)
    }

    func resetPlaybackRateOptions() {
        playbackRateOptionsRaw = PlaybackRate.storageValue(for: PlaybackRate.defaultOptions)
        setPlaybackRate(.normal)
    }

    private func restartPlaybackForUpdatedRate(loop: Bool) async {
        guard !currentText.isEmpty else { return }
        playbackGeneration += 1
        let generation = playbackGeneration

        ttsState = .loading
        audioPlayer.reset()
        await stopFallbackPlayback()

        let result = await ttsManager.synthesize(text: currentText, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audioData(let audioData):
            do {
                try audioPlayer.play(data: audioData, loop: loop)
                isLooping = loop
                ttsState = .playing
                logger.info("Restarted playback with updated rate")
            } catch {
                isLooping = false
                ttsState = .error(error.localizedDescription)
                logger.error("Failed to restart audio after rate change: \(error.localizedDescription)")
            }

        case .fallbackUsed(let utteranceGeneration):
            isLooping = false
            activeFallbackGeneration = utteranceGeneration
            ttsState = .playing
            logger.info("Fallback TTS playback restarted after rate change")

        case .failed(let error):
            isLooping = false
            ttsState = .error(error.localizedDescription)
            logger.error("TTS synthesis failed after rate change: \(error.localizedDescription)")
        }
    }

    // MARK: - Panel Management

    private func showPanel() {
        logger.debug("Showing floating panel")

        if floatingPanel == nil {
            floatingPanel = FloatingPanel()
        }

        let requestID = currentRequestID
        floatingPanel?.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentRequestID == requestID else { return }
                self.stopTTS()
            }
        }

        guard let panel = floatingPanel else {
            logger.error("Failed to create floating panel")
            return
        }

        isPanelVisible = true

        DispatchQueue.main.async {
            let panelContent = TranslationView(appState: self)
            let hostingController = NSHostingController(rootView: panelContent)
            panel.contentViewController = hostingController
            panel.setContentSize(NSSize(width: 420, height: 180))
            panel.center()
            // No NSApp.activate here: the panel is .nonactivatingPanel by design so the
            // source app keeps focus; makeKeyAndOrderFront is enough for Esc and clicks.
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func resizePanelToFitContent() {
        guard let panel = floatingPanel,
              let hostingController = panel.contentViewController as? NSHostingController<TranslationView>,
              isSingleWordSelection
        else {
            return
        }

        DispatchQueue.main.async {
            let targetWidth: CGFloat = 560
            let fittedSize = hostingController.sizeThatFits(in: NSSize(width: targetWidth, height: .greatestFiniteMagnitude))
            let contentSize = NSSize(
                width: max(420, min(fittedSize.width, targetWidth)),
                height: max(170, fittedSize.height)
            )
            panel.setContentSize(contentSize)
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
            soundOnlyPanel = FloatingPanel(contentSize: NSSize(width: 180, height: 40), borderless: true)
        }

        let requestID = currentRequestID
        soundOnlyPanel?.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentRequestID == requestID else { return }
                self.stopTTS()
            }
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
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
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

    // MARK: - Collection

    var isCurrentSavedInCollection: Bool {
        guard !currentText.isEmpty else { return false }
        return collectionStore.contains(sourceText: currentText)
    }

    /// True when there's a user-visible translation/dictionary result that's eligible to save.
    var canSaveCurrentToCollection: Bool {
        guard !currentText.isEmpty else { return false }
        if isTranslating || isTranslatingDefinitions { return false }
        return dictionaryResult != nil || translation != nil
    }

    func toggleSaveCurrentToCollection() {
        guard !currentText.isEmpty else { return }

        if collectionStore.contains(sourceText: currentText) {
            if let existing = collectionStore.items.first(where: {
                $0.normalizedKey == CollectionItem.normalizedKey(for: currentText)
            }) {
                collectionStore.remove(id: existing.id)
                logger.info("Removed item from collection")
            }
            return
        }

        let item: CollectionItem?
        if let dict = dictionaryResult {
            item = CollectionItem.from(dictionaryResult: dict, sourceText: currentText)
        } else if let translation = translation {
            item = CollectionItem.from(translation: translation, sourceText: currentText)
        } else {
            item = nil
        }

        guard let item else {
            logger.info("Save requested but no translation/dictionary result available")
            return
        }

        collectionStore.add(item)
        logger.info("Saved item to collection")
    }

    /// Synthesize and play arbitrary text (used by the Collection window and voice preview).
    /// Stops any prior playback and does not touch translation state.
    func playCollectionItem(text: String) {
        startPlayback { await self.performCollectionPlayback(text: text) }
    }

    private func performCollectionPlayback(text: String) async {
        guard !text.isEmpty else { return }
        logger.info("Playing collection item")
        playbackGeneration += 1
        let generation = playbackGeneration

        isLooping = false
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        audioPlayer.reset()
        await stopFallbackPlayback()

        ttsState = .loading

        let result = await ttsManager.synthesize(text: text, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audioData(let audioData):
            do {
                try audioPlayer.play(data: audioData)
                ttsState = .playing
            } catch {
                ttsState = .error(error.localizedDescription)
                logger.error("Collection playback failed: \(error.localizedDescription)")
            }
        case .fallbackUsed(let utteranceGeneration):
            activeFallbackGeneration = utteranceGeneration
            ttsState = .playing
        case .failed(let error):
            ttsState = .error(error.localizedDescription)
            logger.error("Collection TTS synthesis failed: \(error.localizedDescription)")
        }
    }

    /// Plays a short sample phrase without disturbing the current selection,
    /// translation, or collection state (used by Settings → Preview voice).
    func previewVoice() {
        playCollectionItem(text: "Hello, I am SoundsRight.")
    }

    func showCollectionWindow() {
        if collectionWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Collection"
            window.contentView = NSHostingView(rootView: CollectionWindowView(appState: self))
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("CollectionWindow")
            window.minSize = NSSize(width: 560, height: 360)
            collectionWindow = window
        }
        activateApp()
        collectionWindow?.makeKeyAndOrderFront(nil)
    }

    /// Activates the app for regular windows (Collection, Settings) using the
    /// non-deprecated API where available.
    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Settings Window

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
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
        activateApp()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// NOTE: FloatingPanel is defined in UI/FloatingPanel.swift
// NOTE: TranslationView is defined in UI/TranslationView.swift
