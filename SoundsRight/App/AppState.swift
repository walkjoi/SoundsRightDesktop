import SwiftUI
import KeyboardShortcuts
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

    /// True while the panel is pinned: it survives clicks outside and keeps
    /// its position across activations instead of re-anchoring at the cursor.
    @Published var isPanelPinned: Bool = false

    /// True when the current selection exceeded `maxInputLength` and was cut.
    @Published var wasInputTruncated: Bool = false

    /// True while the offline AVSpeech fallback voice is what the user hears —
    /// shown as a badge so the quality drop (and disabled loop) is explained.
    @Published var isUsingFallbackVoice: Bool = false

    /// Index (into the whitespace-separated words of `currentText`) of the word
    /// currently being spoken — drives read-along highlighting. Nil when idle,
    /// between playbacks, or when the audio came without word timings.
    @Published private(set) var spokenWordIndex: Int?

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
    @AppStorage("ttsVoice") var ttsVoiceRaw: String = AppConstants.defaultVoice.rawValue
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false

    var ttsVoice: TTSVoice {
        TTSVoice(rawValue: ttsVoiceRaw) ?? AppConstants.defaultVoice
    }

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
    let recentLookupStore = RecentLookupStore()

    // MARK: - Panel Management

    private var floatingPanel: FloatingPanel?
    private var soundOnlyPanel: FloatingPanel?
    private var toastPanel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var collectionWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var welcomeCloseObserver: NSObjectProtocol?
    private var isInitialized = false
    private var lastActivationMode: ActivationMode = .translation
    private var hideSoundOnlyTask: Task<Void, Never>?
    private var hideToastTask: Task<Void, Never>?
    private var restartPlaybackTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var isPresentingAccessibilityAlert = false

    /// Global + local mouse-down monitors that implement click-outside-dismisses
    /// (Look Up-style transience). Installed while the panel is visible and unpinned.
    private var outsideClickMonitors: [Any] = []

    /// Monotonic ID for playback intents (hotkey play, collection play, rate restart).
    /// Captured before `synthesize` and checked after, so a superseded synthesis
    /// cannot clobber a newer one's audio or state.
    private var playbackGeneration = 0

    /// Generation of the live AVSpeech fallback utterance, nil when playback is
    /// audio-data-backed (or idle). Lets finish/cancel events and stop requests be
    /// attributed to the exact utterance instead of a racy Bool.
    private var activeFallbackGeneration: Int?

    /// Word timings for the audio currently loaded in the player. Outlives the
    /// tracking task so loop/replay of the same audio can re-track.
    private var currentWordBoundaries: [WordBoundary] = []
    private var readAlongTask: Task<Void, Never>?

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

        // On the very first run the welcome window drives the Accessibility
        // grant — firing the system prompt here too would put two competing
        // permission UIs on screen at once. (The prompting call is still what
        // registers the app in the Accessibility list, so the welcome's
        // "Open System Settings" button triggers it via requestAccessibilityAccess.)
        if hasSeenWelcome {
            SelectionReader.ensureAccessibilityPermission()
        }

        // Update ttsState when audio finishes playing naturally
        audioPlayer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Boundaries are kept so a loop/replay of the same audio re-tracks.
                self.stopReadAlongTracking()
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

        // Teach the hotkeys and walk through the Accessibility grant *before*
        // the first hotkey press can fail.
        if !hasSeenWelcome {
            showWelcomeWindow()
        }
    }

    func shutdown() async {
        logger.info("Shutting down app")
        shortcutManager.unregister()
        audioPlayer.stop()
        await ttsManager.shutdown()
        await collectionStore.flush()
        await recentLookupStore.flush()
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
        await teardownActiveSession(for: mode)

        let selection: SelectionReader.Selection
        switch await SelectionReader.readSelectedText() {
        case .success(let captured):
            selection = captured
        case .failure(.noSelection):
            logger.info("No text selected — telling the user")
            showToast(
                "No text selected — select some text, then press the shortcut",
                style: .notice
            )
            return
        case .failure(.readInProgress):
            logger.info("Selection read already in progress — ignoring activation")
            return
        case .failure(.noPermission):
            logger.warning("Accessibility permission missing — prompting user")
            presentAccessibilityAlert()
            return
        case .failure(.eventCreationFailed):
            logger.error("Could not synthesize Cmd+C event — telling the user")
            showToast("Couldn't read the selection — try again", style: .notice)
            return
        }

        guard requestID == currentRequestID else { return }

        await beginSession(
            text: selection.text,
            truncated: selection.wasTruncated,
            mode: mode,
            requestID: requestID
        )
    }

    /// Activation from a menu bar row: gives the menu window a beat to close so
    /// key focus returns to the user's app before the synthetic ⌘C fires.
    func activateFromMenu(mode: ActivationMode) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.activate(mode: mode)
        }
    }

    /// Re-opens a remembered lookup (menu bar → Recent) without touching the
    /// user's current selection.
    func presentRecentLookup(_ lookup: RecentLookup) {
        Task { @MainActor in
            self.currentRequestID += 1
            let requestID = self.currentRequestID
            await self.teardownActiveSession(for: .translation)
            await self.beginSession(
                text: lookup.text,
                truncated: false,
                mode: .translation,
                requestID: requestID
            )
        }
    }

    /// Promotes a Sound-Only session to the full translation panel: same capture,
    /// same audio (playback is deliberately left untouched), translation starts now.
    func expandSoundOnlyToTranslation() {
        guard !currentText.isEmpty else { return }
        logger.info("Expanding sound-only session to translation panel")

        lastActivationMode = .translation
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        soundOnlyPanel?.orderOut(nil)

        showPanel()
        recentLookupStore.record(text: currentText)

        let requestID = currentRequestID
        Task { @MainActor in
            await self.startTranslation(requestID: requestID)
        }
    }

    /// Stops playback/tasks from the previous activation and hides its surfaces.
    /// A pinned panel is left in place when the next session will reuse it.
    private func teardownActiveSession(for mode: ActivationMode) async {
        lastActivationMode = mode
        isLooping = false
        playbackGeneration += 1
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer.reset()
        stopReadAlong()
        await stopFallbackPlayback()
        if !(isPanelPinned && mode == .translation) {
            hidePanel()
        }
        soundOnlyPanel?.orderOut(nil)
    }

    /// Common entry for hotkey, menu, and recent-lookup activations once the
    /// text is known: resets result state, shows the right surface, starts work.
    private func beginSession(
        text: String,
        truncated: Bool,
        mode: ActivationMode,
        requestID: Int
    ) async {
        currentText = text
        translation = nil
        dictionaryResult = nil
        translationError = nil
        pendingDictionaryResult = nil
        pendingTranslation = nil
        isTranslating = false
        isTranslatingDefinitions = false
        ttsState = .idle
        wasInputTruncated = truncated
        isUsingFallbackVoice = false

        recentLookupStore.record(text: text)

        switch mode {
        case .translation:
            showPanel()
            if autoPlay {
                startPlayback { await self.playTTS() }
            }
            await startTranslation(requestID: requestID)
        case .soundOnly:
            showSoundOnlyHUD()
            if truncated {
                showToast("Reading the first \(AppConstants.maxInputLength) characters")
            }
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

        // Accessory (LSUIElement) apps aren't active when a global hotkey fires;
        // without activating first the alert can appear unfocused behind the
        // frontmost app — invisible, while the guard above swallows retries.
        activateApp()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        SoundsRight reads the selected text by simulating Cmd+C, which needs \
        Accessibility access. Enable SoundsRight in System Settings → \
        Privacy & Security → Accessibility, then press the shortcut again.

        If SoundsRight already appears enabled in the list, toggle it off and \
        back on — the grant is tied to the exact build of the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityAccess()
        }
    }

    /// Registers the app with TCC (the prompting check is the only public API
    /// that adds it to the Accessibility list) and opens the pane — so the list
    /// the user lands in actually contains SoundsRight, even on a first run.
    func requestAccessibilityAccess() {
        SelectionReader.ensureAccessibilityPermission()
        openAccessibilitySettings()
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Human-readable label for a registered hotkey, e.g. "⌥⌘X".
    static func shortcutLabel(for name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:)) ?? "—"
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
                    recentLookupStore.record(text: currentText, summary: result.meanings.first?.definition)
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
        recentLookupStore.record(text: currentText, summary: text)
        resizePanelToFitContent()
        logger.info("Translation succeeded")
    }

    /// Called by TranslationView when Apple Translation fails.
    func didFailTranslation(_ error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        translationError = error.localizedDescription
        pendingTranslation = nil
        isTranslating = false
        resizePanelToFitContent()
        logger.error("Translation failed: \(error.localizedDescription)")
    }

    /// Called by TranslationView after batched dictionary definition translation succeeds.
    func didFinishDictionaryTranslation(_ result: DictionaryResult, requestID: Int) {
        guard requestID == currentRequestID else { return }
        dictionaryResult = result
        pendingDictionaryResult = nil
        isTranslatingDefinitions = false
        recentLookupStore.record(
            text: currentText,
            summary: result.meanings.first.map { $0.translatedDefinition ?? $0.definition }
        )
        resizePanelToFitContent()
        logger.info("Dictionary definitions translated")
    }

    /// Called by TranslationView when dictionary translation fails — fall back to English-only result.
    func didFailDictionaryTranslation(fallback: DictionaryResult, error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        dictionaryResult = fallback
        pendingDictionaryResult = nil
        isTranslatingDefinitions = false
        recentLookupStore.record(text: currentText, summary: fallback.meanings.first?.definition)
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
        stopReadAlong()
        await stopFallbackPlayback()

        let result = await ttsManager.synthesize(text: currentText, voice: ttsVoice, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            // Superseded — if our synthesize already started fallback speech, silence
            // it (generation-scoped, so a newer utterance is never touched).
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audio(let audio):
            do {
                try audioPlayer.play(data: audio.data)
                isUsingFallbackVoice = false
                ttsState = .playing
                startReadAlong(with: audio.wordBoundaries)
                logger.info("Audio playback started")
            } catch {
                ttsState = .error(error.localizedDescription)
                logger.error("Failed to play audio: \(error.localizedDescription)")
            }

        case .fallbackUsed(let utteranceGeneration):
            activeFallbackGeneration = utteranceGeneration
            isUsingFallbackVoice = true
            ttsState = .playing
            logger.info("Fallback TTS playback started")

        case .failed(let error):
            ttsState = .error(Self.friendlyTTSMessage(for: error))
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Read-Along

    /// Begins highlighting words in step with the audio the panel just started.
    private func startReadAlong(with boundaries: [WordBoundary]) {
        currentWordBoundaries = boundaries
        startReadAlongTracking()
    }

    /// (Re)starts the polling task over the retained boundaries — used directly
    /// when looping replays audio whose timings we already hold.
    private func startReadAlongTracking() {
        readAlongTask?.cancel()
        readAlongTask = nil
        spokenWordIndex = nil
        guard !currentWordBoundaries.isEmpty else { return }

        readAlongTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updateSpokenWordIndex()
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    /// Stops highlight updates but keeps the timings for a later loop/replay.
    private func stopReadAlongTracking() {
        readAlongTask?.cancel()
        readAlongTask = nil
        spokenWordIndex = nil
    }

    /// Full teardown: the loaded audio (and thus its timings) is going away.
    private func stopReadAlong() {
        stopReadAlongTracking()
        currentWordBoundaries = []
    }

    private func updateSpokenWordIndex() {
        guard !currentWordBoundaries.isEmpty else { return }
        let time = audioPlayer.currentTime

        // Last word whose start we've passed. Recomputed from scratch each tick
        // so looped playback (currentTime wrapping to 0) re-tracks naturally.
        var newIndex: Int?
        for (index, boundary) in currentWordBoundaries.enumerated() {
            if time >= boundary.time {
                newIndex = index
            } else {
                break
            }
        }

        // Clear the highlight once the final word has finished sounding.
        if let index = newIndex, index == currentWordBoundaries.count - 1 {
            let boundary = currentWordBoundaries[index]
            if time > boundary.time + max(boundary.duration, 0.05) + 0.25 {
                newIndex = nil
            }
        }

        if spokenWordIndex != newIndex {
            spokenWordIndex = newIndex
        }
    }

    /// Maps transport-level TTS failures to language a user can act on.
    private static func friendlyTTSMessage(for error: Error) -> String {
        switch error {
        case EdgeTTSService.EdgeTTSError.connectionFailed:
            return "Couldn't reach the voice service — check your internet connection"
        case EdgeTTSService.EdgeTTSError.synthesisTimedOut:
            return "The voice service took too long to respond"
        case EdgeTTSService.EdgeTTSError.noAudioReceived,
             EdgeTTSService.EdgeTTSError.unexpectedMessage:
            return "The voice service returned no audio"
        default:
            return error.localizedDescription
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
        stopReadAlong()
        activeFallbackGeneration = nil
        Task { await ttsManager.stopPlayback() }
        ttsState = .idle
    }

    func toggleLoop() {
        if isLooping {
            logger.info("Stopping loop")
            isLooping = false
            audioPlayer.stop()
            // Keep the boundaries: the audio data is still loaded for replay.
            stopReadAlongTracking()
            ttsState = .idle
        } else {
            // Looping replays buffered audio data; fallback speech has none.
            guard activeFallbackGeneration == nil else { return }
            logger.info("Starting loop")
            do {
                try audioPlayer.replayLooping()
                isLooping = true
                ttsState = .playing
                startReadAlongTracking()
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
        stopReadAlong()
        await stopFallbackPlayback()

        let result = await ttsManager.synthesize(text: currentText, voice: ttsVoice, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audio(let audio):
            do {
                try audioPlayer.play(data: audio.data, loop: loop)
                isLooping = loop
                isUsingFallbackVoice = false
                ttsState = .playing
                startReadAlong(with: audio.wordBoundaries)
                logger.info("Restarted playback with updated rate")
            } catch {
                isLooping = false
                ttsState = .error(error.localizedDescription)
                logger.error("Failed to restart audio after rate change: \(error.localizedDescription)")
            }

        case .fallbackUsed(let utteranceGeneration):
            isLooping = false
            activeFallbackGeneration = utteranceGeneration
            isUsingFallbackVoice = true
            ttsState = .playing
            logger.info("Fallback TTS playback restarted after rate change")

        case .failed(let error):
            isLooping = false
            ttsState = .error(Self.friendlyTTSMessage(for: error))
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
                self.isPanelVisible = false
                self.isPanelPinned = false
                self.removeOutsideClickMonitors()
            }
        }
        floatingPanel?.onKeyCommand = { [weak self] command in
            self?.handlePanelKeyCommand(command) ?? false
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
            // Fixed position: dead center, every show. Assigning the content
            // view controller resizes the window, so centering must come after.
            panel.center()
            // No NSApp.activate here: the panel is .nonactivatingPanel by design so the
            // source app keeps focus; makeKeyAndOrderFront is enough for Esc and clicks.
            panel.makeKeyAndOrderFront(nil)
            self.installOutsideClickMonitorsIfNeeded()
        }
    }

    /// Places `panel` next to the mouse (below for negative y offsets), clamped
    /// to the screen's visible frame — used by the toast (the HUD does its own).
    private static func position(_ panel: NSPanel, nearCursorWithSize size: NSSize, offset: NSPoint) {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(
            x: mouse.x + offset.x,
            y: offset.y < 0 ? mouse.y - size.height + offset.y : mouse.y + offset.y
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        panel.setFrameOrigin(origin)
    }

    private func resizePanelToFitContent() {
        guard let panel = floatingPanel,
              let hostingController = panel.contentViewController as? NSHostingController<TranslationView>
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
            // Re-center after the content-driven resize so the panel stays
            // fixed at screen center regardless of how tall the result is.
            panel.setContentSize(contentSize)
            panel.center()
        }
    }

    private func hidePanel() {
        logger.debug("Hiding floating panel")
        floatingPanel?.orderOut(nil)
        isPanelVisible = false
        isPanelPinned = false
        removeOutsideClickMonitors()
    }

    func dismiss() {
        logger.info("Dismissing panel and stopping playback")
        stopTTS()
        hidePanel()
    }

    // MARK: - Panel Pinning & Transience

    func togglePanelPin() {
        isPanelPinned.toggle()
        logger.info("Panel pin toggled: \(self.isPanelPinned)")
        if isPanelPinned {
            removeOutsideClickMonitors()
        } else {
            installOutsideClickMonitorsIfNeeded()
        }
    }

    /// Look Up-style transience: while the panel is visible and unpinned, any
    /// mouse-down outside it dismisses it. The global monitor covers clicks in
    /// other apps; the local one covers clicks in our own windows.
    private func installOutsideClickMonitorsIfNeeded() {
        guard outsideClickMonitors.isEmpty, isPanelVisible, !isPanelPinned else { return }

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            // Global monitor handlers are documented to run on the main thread.
            MainActor.assumeIsolated {
                self?.dismissPanelIfClickedOutside(at: NSEvent.mouseLocation, window: nil)
            }
        }) {
            outsideClickMonitors.append(globalMonitor)
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissPanelIfClickedOutside(at: NSEvent.mouseLocation, window: event.window)
            }
            return event
        }) {
            outsideClickMonitors.append(localMonitor)
        }
    }

    private func removeOutsideClickMonitors() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll()
    }

    private func dismissPanelIfClickedOutside(at location: NSPoint, window: NSWindow?) {
        guard isPanelVisible, !isPanelPinned, let panel = floatingPanel else { return }
        if let window, window === panel { return }
        guard !panel.frame.contains(location) else { return }
        logger.debug("Click outside panel — dismissing")
        dismiss()
    }

    // MARK: - Toast

    /// Shows a transient, non-interactive capsule near the cursor. Used whenever
    /// an activation can't do what was asked — a hotkey press must never
    /// resolve to nothing — and for small confirmations ("Copied").
    func showToast(_ message: String, style: ToastView.Style = .info) {
        hideToastTask?.cancel()
        hideToastTask = nil

        if toastPanel == nil {
            let panel = FloatingPanel(contentSize: NSSize(width: 220, height: 36), borderless: true)
            panel.ignoresMouseEvents = true
            toastPanel = panel
        }
        guard let panel = toastPanel else { return }

        let hostingView = NSHostingView(rootView: ToastView(message: message, style: style))
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        panel.setContentSize(size)
        // Above-right of the cursor, so it never collides with the HUD (below-right).
        Self.position(panel, nearCursorWithSize: size, offset: NSPoint(x: 12, y: 16))
        panel.alphaValue = 1
        panel.orderFront(nil)

        hideToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppConstants.toastDisplayDuration * 1_000_000_000))
            guard !Task.isCancelled, let panel = self?.toastPanel else { return }
            panel.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: - Panel Keyboard Commands

    /// Plain-key vocabulary while the panel is key: Space play/pause, L loop,
    /// S save, C copy, 1–5 direct speed. Returns false when the command doesn't
    /// apply so the key falls through.
    private func handlePanelKeyCommand(_ command: PanelKeyCommand) -> Bool {
        switch command {
        case .togglePlayPause:
            togglePlayPause()
            return true
        case .toggleLoop:
            guard hasAudioData else { return false }
            toggleLoop()
            return true
        case .toggleSave:
            guard canSaveCurrentToCollection || isCurrentSavedInCollection else { return false }
            toggleSaveCurrentToCollection()
            return true
        case .copyTranslation:
            guard canCopyTranslation else { return false }
            copyTranslationToClipboard()
            return true
        case .setRate(let index):
            let rates = PlaybackRate.allCases
            guard (1...rates.count).contains(index) else { return false }
            setPlaybackRate(rates[index - 1])
            return true
        }
    }

    // MARK: - Copy Translation

    var canCopyTranslation: Bool {
        translation != nil || dictionaryResult != nil
    }

    /// Copies the visible result: the sentence translation, or the dictionary
    /// entry as "word / phonetics / part-of-speech: definition — 中文" lines.
    func copyTranslationToClipboard() {
        let text: String?
        if let dictionary = dictionaryResult {
            var lines: [String] = [dictionary.word]
            if !dictionary.phonetics.isEmpty {
                lines.append(dictionary.phonetics.joined(separator: "  "))
            }
            for meaning in dictionary.meanings {
                var line = "\(meaning.partOfSpeech): \(meaning.definition)"
                if let translated = meaning.translatedDefinition {
                    line += " — \(translated)"
                }
                lines.append(line)
            }
            text = lines.joined(separator: "\n")
        } else if let translation {
            text = translation.translated
        } else {
            text = nil
        }

        guard let text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Copied translation to clipboard")
        showToast("Copied")
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

    // MARK: - Welcome Guide

    func showWelcomeWindow() {
        if welcomeWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 512),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to SoundsRight"
            window.contentView = NSHostingView(rootView: WelcomeView(appState: self))
            window.center()
            window.isReleasedWhenClosed = false
            welcomeWindow = window

            // The red close button must count as "done" too — only the
            // Get Started button sets hasSeenWelcome otherwise, and a guide
            // that reopens on every launch reads as the app forgetting state.
            welcomeCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasSeenWelcome = true
                }
            }
        }
        activateApp()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    /// Called by the welcome guide's "Get Started" button.
    func finishWelcome() {
        hasSeenWelcome = true
        welcomeWindow?.orderOut(nil)
    }

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
        // Collection audio plays without read-along: the panel's text (if any)
        // is not what this audio speaks.
        stopReadAlong()
        await stopFallbackPlayback()

        ttsState = .loading

        let result = await ttsManager.synthesize(text: text, voice: ttsVoice, rate: playbackRate)
        guard generation == playbackGeneration, !Task.isCancelled else {
            if case .fallbackUsed(let utteranceGeneration) = result {
                await ttsManager.stopFallback(generation: utteranceGeneration)
            }
            return
        }

        switch result {
        case .audio(let audio):
            do {
                try audioPlayer.play(data: audio.data)
                isUsingFallbackVoice = false
                ttsState = .playing
            } catch {
                ttsState = .error(error.localizedDescription)
                logger.error("Collection playback failed: \(error.localizedDescription)")
            }
        case .fallbackUsed(let utteranceGeneration):
            activeFallbackGeneration = utteranceGeneration
            isUsingFallbackVoice = true
            ttsState = .playing
        case .failed(let error):
            ttsState = .error(Self.friendlyTTSMessage(for: error))
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
