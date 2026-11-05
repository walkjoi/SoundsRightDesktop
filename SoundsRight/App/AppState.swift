import SwiftUI
import KeyboardShortcuts
import os

/// What the panel's result area holds for the current lookup. One value
/// instead of independent flags, so a lookup cannot be "loading" and "failed"
/// at once, or show an error on top of the dictionary entry that replaced it.
enum LookupState {
    case idle
    /// Nothing to show yet: a sentence translation, or a word's dictionary
    /// lookup racing its plain translation.
    case loading
    case translated(TranslationResult)
    /// Word, phonetics and English definitions are ready; the Chinese
    /// definitions are still being translated while `translatingDefinitions`.
    /// An English-only entry (older macOS, or a failed batch) ends at false.
    case dictionary(DictionaryResult, translatingDefinitions: Bool)
    case failed(String)
}

/// What is producing the sound while playback is live.
enum PlaybackSource: Equatable {
    /// Synthesized (or cached) audio data in `AudioPlayer`; only this kind can
    /// loop or replay.
    case audio(looping: Bool)
    /// The AVSpeech fallback voice, identified by its utterance generation so
    /// finish/cancel events and stop requests reach the exact utterance.
    case fallback(generation: Int)
}

/// What a playback speaks, which decides what it may do and which surface
/// shows it. Only lookup playback honors repeat, drives read along, and
/// appears in the panel and HUD; a rate change restarts whichever is live.
enum PlaybackSubject: Equatable {
    /// The current lookup's text, `AppState.currentText`.
    case lookup
    /// Other text spoken once: a Collection row, a review card, or the voice
    /// preview. It never loops and has no read along, because the panel's
    /// text is not what it speaks.
    case oneShot(String)
}

/// The one source of truth for playback. The source, loop mode and subject
/// live inside the cases rather than in flags beside them, so "looping
/// fallback speech" or "a fallback generation while idle" cannot be
/// represented, and nothing has to guess what the audio is.
enum TTSPlaybackState {
    case idle
    case loading(PlaybackSubject)
    case playing(PlaybackSource, PlaybackSubject)
    case paused(PlaybackSource, PlaybackSubject)
    case finished(PlaybackSubject)
    case error(String, PlaybackSubject)

    var isPlayingOrLoading: Bool {
        switch self {
        case .loading, .playing:
            return true
        case .idle, .paused, .finished, .error:
            return false
        }
    }

    /// The live source while playing or paused; nil otherwise.
    var source: PlaybackSource? {
        switch self {
        case .playing(let source, _), .paused(let source, _):
            return source
        case .idle, .loading, .finished, .error:
            return nil
        }
    }

    /// What the live or most recent playback speaks; nil when idle.
    var subject: PlaybackSubject? {
        switch self {
        case .idle:
            return nil
        case .loading(let subject),
             .playing(_, let subject),
             .paused(_, let subject),
             .finished(let subject),
             .error(_, let subject):
            return subject
        }
    }

    /// This state as a surface showing `subject` renders it: unchanged when
    /// the playback is that subject's, idle while the player is busy with
    /// another, so a Collection row never shows as the panel's audio.
    func filtered(to subject: PlaybackSubject) -> TTSPlaybackState {
        self.subject == subject ? self : .idle
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var currentText: String = ""
    @Published var lookup: LookupState = .idle

    var translation: TranslationResult? {
        if case .translated(let result) = lookup { return result }
        return nil
    }

    var dictionaryResult: DictionaryResult? {
        if case .dictionary(let result, _) = lookup { return result }
        return nil
    }

    var isTranslating: Bool {
        if case .loading = lookup { return true }
        return false
    }

    var translationError: String? {
        if case .failed(let message) = lookup { return message }
        return nil
    }

    /// True while the Chinese translation of dictionary definitions is in flight — word + phonetics are already visible.
    var isTranslatingDefinitions: Bool {
        if case .dictionary(_, translatingDefinitions: true) = lookup { return true }
        return false
    }

    @Published var ttsState: TTSPlaybackState = .idle {
        didSet { updateSpeechEscapeClaim() }
    }

    /// Playback as the panel and HUD render it. They show the lookup, so a
    /// Collection row or the voice preview playing reads as idle there.
    var lookupPlayback: TTSPlaybackState { ttsState.filtered(to: .lookup) }

    @Published var isPanelVisible: Bool = false {
        didSet { updateSpeechEscapeClaim() }
    }

    /// True while the panel is pinned: it survives clicks outside and keeps
    /// its position across activations instead of re-anchoring at the cursor.
    @Published var isPanelPinned: Bool = false

    /// True when the current selection exceeded `maxInputLength` and was cut.
    @Published var wasInputTruncated: Bool = false

    /// True while the offline AVSpeech fallback voice is speaking the lookup,
    /// shown as a badge in the panel and HUD so the quality drop (and the
    /// disabled loop) is explained.
    var isUsingFallbackVoice: Bool {
        if case .fallback? = lookupPlayback.source { return true }
        return false
    }

    /// Generation of the live fallback utterance, nil when playback is
    /// audio-data-backed or not live.
    private var fallbackGeneration: Int? {
        if case .fallback(let generation)? = ttsState.source {
            return generation
        }
        return nil
    }

    /// Index (into the whitespace-separated words of `currentText`) of the word
    /// currently being spoken — drives read-along highlighting. Nil when idle,
    /// between playbacks, or when the audio came without word timings.
    @Published private(set) var spokenWordIndex: Int?

    /// True when the loaded audio is the lookup's, so the panel and HUD may
    /// loop or replay it. A one shot's audio is not theirs to replay.
    var hasLookupAudio: Bool {
        audioPlayer.hasAudioData && ttsState.subject == .lookup
    }

    /// Incrementing this (re)arms the translation session task in TranslationView
    /// (Apple Translation framework) when no resident work loop is running.
    @Published var translationWorkTrigger: Int = 0

    struct PendingDictionaryResult: Sendable {
        let requestID: Int
        let result: DictionaryResult
    }

    struct PendingTranslation: Sendable {
        let requestID: Int
        let text: String
    }

    /// One unit of work for the shared Apple Translation session — the language
    /// pair is en → zh-Hans for both cases, so a single warm session serves
    /// sentence translation and dictionary-definition batches alike.
    enum TranslationWork: Sendable {
        case sentence(PendingTranslation)
        case dictionaryDefinitions(PendingDictionaryResult)
    }

    /// Work waiting for the session task in TranslationView to (re)start. Live
    /// work is handed off through `translationWorkContinuation` instead.
    private var pendingTranslationWork: TranslationWork?

    /// Feed of the resident translation loop in TranslationView; nil when no
    /// loop is consuming (before the panel first arms, or after an error).
    private var translationWorkContinuation: AsyncStream<TranslationWork>.Continuation?

    /// Monotonic ID for work streams, so a stale stream's termination cannot
    /// clear a newer stream's continuation.
    private var translationWorkStreamGeneration = 0

    /// Monotonic ID bumped on every activation. Async callbacks guard on this to avoid stale writes.
    private(set) var currentRequestID: Int = 0

    // MARK: - App Storage

    @AppStorage("autoPlay") var autoPlay: Bool = true
    @AppStorage("repeatEnabled") var repeatEnabled: Bool = false
    @AppStorage("playbackRate") var playbackRateRaw: Double = 1.0
    @AppStorage("playbackRateOptions") var playbackRateOptionsRaw: String =
        PlaybackRate.storageValue(for: PlaybackRate.defaultOptions)
    @AppStorage("ttsVoice") var ttsVoiceRaw: String = AppConstants.defaultVoice.rawValue
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false
    @AppStorage("activationTrigger") var activationTriggerRaw: String = ActivationTrigger.shortcut.rawValue

    var ttsVoice: TTSVoice {
        TTSVoice(rawValue: ttsVoiceRaw) ?? AppConstants.defaultVoice
    }

    var activationTrigger: ActivationTrigger {
        ActivationTrigger(rawValue: activationTriggerRaw) ?? .shortcut
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
    private let hoverTriggerMonitor = HoverTriggerMonitor()
    let collectionStore = CollectionStore()
    let recentLookupStore = RecentLookupStore()
    let dictationController = DictationController()

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

    /// Word timings for the audio currently loaded in the player. Outlives the
    /// tracking task so loop/replay of the same audio can re-track.
    private var currentWordBoundaries: [WordBoundary] = []
    private var readAlongTask: Task<Void, Never>?

    /// Completed lookups served instantly on repeat. Keyed by the exact
    /// selection text (sentences) or the lowercased word (dictionary entries;
    /// only fully translated entries are cached).
    private var translationCache = LRUCache<String, TranslationResult>(capacity: AppConstants.lookupCacheMaxEntries)
    private var dictionaryCache = LRUCache<String, DictionaryResult>(capacity: AppConstants.lookupCacheMaxEntries)

    /// When the current lookup's translation work started — for latency logging.
    private var lookupStartedAt: ContinuousClock.Instant?

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
                // A looping player never finishes; turning repeat off lets the
                // current pass run out, by which point the state says not looping.
                if case .playing(.audio, let subject) = self.ttsState {
                    self.ttsState = .finished(subject)
                    // Only the Sound Only session's own speech closes its HUD,
                    // not a Collection row that played while it was up.
                    if subject == .lookup, self.lastActivationMode == .soundOnly {
                        self.hideSoundOnlyHUD()
                    }
                }
            }
        }

        // A decode failure stops the player without a finish callback; left
        // unhandled, ttsState would stay .playing and keep Esc claimed.
        audioPlayer.onFailed = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.ttsState {
                case .playing(.audio, let subject), .paused(.audio, let subject):
                    // The data is unplayable; replaying or looping it would fail again.
                    self.audioPlayer.reset()
                    self.stopReadAlong()
                    self.ttsState = .error("Couldn't play the audio", subject)
                case .idle, .loading, .playing(.fallback, _), .paused(.fallback, _), .finished, .error:
                    break
                }
            }
        }

        // Mirror of audioPlayer.onFinished for the AVSpeech fallback path.
        // Covers .paused as well: a pause click racing the utterance's natural
        // finish must not strand the UI in a paused state with no speech to resume.
        await ttsManager.setFallbackFinishedHandler { [weak self] generation, finishedNaturally in
            guard let self, generation == self.fallbackGeneration,
                  let subject = self.ttsState.subject else { return }
            guard finishedNaturally else {
                // Every stop we issue moves ttsState off this utterance first,
                // so a cancel that still matches came from outside; without
                // this the UI would show speech that is no longer there.
                self.ttsState = .idle
                return
            }
            self.ttsState = .finished(subject)
            // Fallback speech never loops. As with audio, only the session's
            // own speech closes the Sound Only HUD.
            if subject == .lookup, self.lastActivationMode == .soundOnly {
                self.hideSoundOnlyHUD()
            }
        }

        // Dictation feeds back through AppState only for the surfaces it shares
        // with lookups: the cursor toast, the Esc claim, and the Accessibility
        // alert that a failed paste would otherwise leave unexplained.
        dictationController.showToast = { [weak self] message, style in
            self?.showToast(message, style: style)
        }
        dictationController.setCancelShortcutEnabled = { [weak self] enabled in
            self?.shortcutManager.setEscapeClaimed(enabled, by: .dictation)
        }
        dictationController.requestAccessibilityGrant = { [weak self] in
            self?.presentAccessibilityAlert()
        }
        await dictationController.initialize()

        shortcutManager.register(
            ShortcutManager.Handlers(
                onTranslate: { [weak self] in
                    Task { @MainActor in
                        await self?.activate(mode: .translation)
                    }
                },
                onSoundOnly: { [weak self] in
                    Task { @MainActor in
                        await self?.activate(mode: .soundOnly)
                    }
                },
                onDictationKeyDown: { [weak self] saveRecording in
                    MainActor.assumeIsolated {
                        self?.dictationController.handleKeyDown(saveRecording: saveRecording)
                    }
                },
                onDictationKeyUp: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.dictationController.handleKeyUp()
                    }
                },
                onDictationCancel: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.dictationController.cancel()
                    }
                },
                onStopSpeech: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.stopSpeakingAndClose()
                    }
                }
            )
        )

        logger.info("Keyboard shortcuts registered")

        hoverTriggerMonitor.onHover = { [weak self] in
            Task { @MainActor in
                await self?.activate(mode: .translation, source: .hover)
            }
        }
        applyActivationTrigger()

        // Teach the hotkeys and walk through the Accessibility grant *before*
        // the first hotkey press can fail.
        if !hasSeenWelcome {
            showWelcomeWindow()
        }
    }

    func shutdown() async {
        logger.info("Shutting down app")
        shortcutManager.unregister()
        hoverTriggerMonitor.stop()
        await dictationController.shutdown()
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
    func activate(mode: ActivationMode, source: ActivationSource = .userInitiated) async {
        currentRequestID += 1
        let requestID = currentRequestID

        // A hotkey/menu activation consumes any armed hover gesture, so the
        // same selection isn't looked up a second time when the pointer rests.
        hoverTriggerMonitor.cancelPendingTrigger()

        logger.info("Activate triggered with mode: \(mode.rawValue), requestID: \(requestID)")
        await teardownActiveSession(for: mode)

        let selection: SelectionReader.Selection
        switch await SelectionReader.readSelectedText() {
        case .success(let captured):
            selection = captured
        case .failure(.noSelection):
            // Hover triggers are speculative (a window drag can arm one), so an
            // empty capture stays silent instead of toasting.
            guard source == .userInitiated else { return }
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
            // Shown for hover too: the user opted into a trigger that can never
            // work without the grant, and the alert guards against stacking.
            logger.warning("Accessibility permission missing — prompting user")
            presentAccessibilityAlert()
            return
        case .failure(.eventCreationFailed):
            guard source == .userInitiated else { return }
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
        playbackGeneration += 1
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer.reset()
        stopReadAlong()
        ttsState = .idle
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
        lookup = .idle
        pendingTranslationWork = nil
        ttsState = .idle
        wasInputTruncated = truncated

        recentLookupStore.record(text: text)

        switch mode {
        case .translation:
            showPanel()
            if autoPlay {
                startPlayback(.lookup)
            }
            await startTranslation(requestID: requestID)
        case .soundOnly:
            showSoundOnlyHUD()
            if truncated {
                showToast("Reading the first \(AppConstants.maxInputLength) characters")
            }
            startPlayback(.lookup)
        }
    }

    /// Cancel-and-replace owner for playback intents: a new one invalidates
    /// the previous play and any pending rate restart (cancellation reaches
    /// TTSManager's fallback guard and stops a synthesis still in flight).
    /// The subject goes into `ttsState` now rather than when the task first
    /// runs, so anything that asks what is playing in between, such as
    /// closing the panel, already sees this intent.
    private func startPlayback(_ subject: PlaybackSubject) {
        logger.info("Starting TTS playback")
        playbackTask?.cancel()
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        ttsState = .loading(subject)
        playbackTask = Task { await self.synthesizeAndPlay(subject) }
    }

    /// Stops any AVSpeech fallback speech. Unconditional (not gated on tracked state):
    /// `FallbackTTSService.stop()` is an idempotent no-op when nothing is speaking, and an
    /// untracked orphan utterance must still be silenced. Callers move `ttsState` off
    /// the utterance first, so its cancel event is recognized as ours.
    private func stopFallbackPlayback() async {
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

    // MARK: - Activation Trigger

    /// Starts or stops the hover monitor to match the persisted trigger
    /// preference. Called at launch and from Settings when the picker changes.
    func applyActivationTrigger() {
        switch activationTrigger {
        case .shortcut:
            hoverTriggerMonitor.stop()
        case .hover:
            hoverTriggerMonitor.start()
        }
        logger.info("Activation trigger applied: \(self.activationTriggerRaw)")
    }

    // MARK: - Translation

    private func startTranslation(requestID: Int) async {
        guard !currentText.isEmpty else { return }
        guard requestID == currentRequestID else { return }

        lookup = .loading
        pendingTranslationWork = nil
        lookupStartedAt = .now

        if let word = translationService.dictionaryLookupCandidate(from: currentText) {
            await lookupWord(word, requestID: requestID)
            return
        }

        if #available(macOS 15, *) {
            startSentenceTranslation(requestID: requestID)
        } else {
            lookup = .failed("Translation requires macOS 15 (Sequoia) or later.")
        }
    }

    private func lookupWord(_ word: String, requestID: Int) async {
        let cacheKey = word.lowercased()

        if let cached = dictionaryCache.value(for: cacheKey) {
            lookup = .dictionary(cached, translatingDefinitions: false)
            recentLookupStore.record(
                text: currentText,
                summary: cached.meanings.first.map { $0.translatedDefinition ?? $0.definition }
            )
            resizePanelToFitContent()
            logLookupLatency("Dictionary lookup served from cache")
            return
        }

        if #available(macOS 15, *) {
            // Race the network lookup: the word's plain translation starts now,
            // so a word the dictionary doesn't know isn't stuck waiting for the
            // failed lookup before translation even begins. The richer
            // dictionary result supersedes it in the UI when it lands.
            startSentenceTranslation(requestID: requestID)
        }

        do {
            let result = try await translationService.lookupDictionaryEntry(for: word)
            guard requestID == currentRequestID else { return }
            if #available(macOS 15, *) {
                lookup = .dictionary(result, translatingDefinitions: true)
                enqueueTranslationWork(.dictionaryDefinitions(
                    PendingDictionaryResult(requestID: requestID, result: result)
                ))
                resizePanelToFitContent()
            } else {
                dictionaryCache.insert(result, for: cacheKey)
                lookup = .dictionary(result, translatingDefinitions: false)
                recentLookupStore.record(text: currentText, summary: result.meanings.first?.definition)
                resizePanelToFitContent()
            }
            logger.info("Dictionary lookup succeeded")
        } catch {
            guard requestID == currentRequestID else { return }
            logger.error("Dictionary lookup failed: \(error.localizedDescription)")
            if #available(macOS 15, *) {
                // The racing sentence translation is already covering this word.
            } else {
                lookup = .failed(error.localizedDescription)
                resizePanelToFitContent()
            }
        }
    }

    /// Serves the translation from cache when possible, otherwise routes it to
    /// the shared translation session.
    @available(macOS 15, *)
    private func startSentenceTranslation(requestID: Int) {
        if let cached = translationCache.value(for: currentText) {
            lookup = .translated(cached)
            recentLookupStore.record(text: currentText, summary: cached.translated)
            resizePanelToFitContent()
            logLookupLatency("Translation served from cache")
            return
        }
        enqueueTranslationWork(.sentence(PendingTranslation(requestID: requestID, text: currentText)))
    }

    /// Called by TranslationView when Apple Translation succeeds.
    func didFinishTranslation(_ text: String, requestID: Int) {
        guard requestID == currentRequestID else { return }
        // For a single word the dictionary entry is the richer answer — once
        // it has landed, the racing sentence translation is redundant.
        if case .dictionary = lookup { return }
        let result = TranslationResult(translated: text)
        translationCache.insert(result, for: currentText)
        lookup = .translated(result)
        recentLookupStore.record(text: currentText, summary: text)
        resizePanelToFitContent()
        logLookupLatency("Translation completed")
    }

    /// Called by TranslationView when Apple Translation fails.
    func didFailTranslation(_ error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        // The most likely cause is a session gone bad — drop the resident loop
        // so the next lookup starts a fresh session.
        resetTranslationSession()
        if case .dictionary = lookup { return }
        lookup = .failed(error.localizedDescription)
        resizePanelToFitContent()
        logger.error("Translation failed: \(error.localizedDescription)")
    }

    /// Called by TranslationView after batched dictionary definition translation succeeds.
    func didFinishDictionaryTranslation(_ result: DictionaryResult, requestID: Int) {
        guard requestID == currentRequestID else { return }
        if let key = translationService.dictionaryLookupCandidate(from: currentText)?.lowercased() {
            dictionaryCache.insert(result, for: key)
        }
        // The dictionary entry supersedes whatever the racing sentence
        // translation produced (or the error it hit).
        lookup = .dictionary(result, translatingDefinitions: false)
        recentLookupStore.record(
            text: currentText,
            summary: result.meanings.first.map { $0.translatedDefinition ?? $0.definition }
        )
        resizePanelToFitContent()
        logLookupLatency("Dictionary definitions translated")
    }

    /// Called by TranslationView when dictionary translation fails — fall back to English-only result.
    /// The English-only entry is shown but deliberately not cached, so the next
    /// lookup of the word retries the translation.
    func didFailDictionaryTranslation(fallback: DictionaryResult, error: Error, requestID: Int) {
        guard requestID == currentRequestID else { return }
        resetTranslationSession()
        lookup = .dictionary(fallback, translatingDefinitions: false)
        recentLookupStore.record(text: currentText, summary: fallback.meanings.first?.definition)
        resizePanelToFitContent()
        logger.error("Dictionary translation failed, showing English-only: \(error.localizedDescription)")
    }

    // MARK: - Translation Session Hub

    /// True while a resident translation loop is consuming work directly.
    var hasLiveTranslationSession: Bool { translationWorkContinuation != nil }

    /// True when work is parked waiting for the session task to (re)start.
    var hasPendingTranslationWork: Bool { pendingTranslationWork != nil }

    /// Called by TranslationView's session task when it (re)starts: hands the
    /// task a fresh work stream and flushes any request that was parked.
    func beginTranslationWorkStream() -> AsyncStream<TranslationWork> {
        translationWorkContinuation?.finish()
        translationWorkStreamGeneration += 1
        let generation = translationWorkStreamGeneration
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationWork.self)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.translationWorkStreamGeneration == generation else { return }
                self.translationWorkContinuation = nil
            }
        }
        translationWorkContinuation = continuation
        if let pending = pendingTranslationWork {
            pendingTranslationWork = nil
            continuation.yield(pending)
        }
        logger.info("Translation work stream started (generation \(generation))")
        return stream
    }

    /// Routes work to the live session loop, or parks it and pokes SwiftUI to
    /// (re)start the session task when none is running.
    private func enqueueTranslationWork(_ work: TranslationWork) {
        if let continuation = translationWorkContinuation,
           case .enqueued = continuation.yield(work) {
            return
        }
        translationWorkContinuation = nil
        pendingTranslationWork = work
        translationWorkTrigger += 1
    }

    /// Ends the resident loop so the next lookup starts a fresh session.
    private func resetTranslationSession() {
        translationWorkContinuation?.finish()
        translationWorkContinuation = nil
    }

    /// Logs how long the current lookup took from `startTranslation` to a
    /// user-visible result — the number to watch when tuning latency.
    private func logLookupLatency(_ label: String) {
        guard let start = lookupStartedAt else { return }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        logger.info("\(label) in \(Int(milliseconds)) ms")
    }

    // MARK: - TTS Playback

    /// The single loading → playing/error transition shared by every playback
    /// intent, so the entry points cannot drift apart. The subject rides in
    /// every state this produces, which is what lets a rate change restart
    /// the right text and each surface tell its own audio from another's.
    private func synthesizeAndPlay(_ subject: PlaybackSubject) async {
        playbackGeneration += 1
        let generation = playbackGeneration
        let text = spokenText(for: subject)

        // Clear stale audio so loop/replay affordances stay disabled while a fresh
        // synthesis (possibly fallback speech with no data) is in flight.
        ttsState = .loading(subject)
        audioPlayer.reset()
        stopReadAlong()
        await stopFallbackPlayback()

        // Replaced while the fallback voice was being stopped (a speed tap,
        // another play): a synthesis started now would only be thrown away.
        guard generation == playbackGeneration, !Task.isCancelled else { return }

        let result = await ttsManager.synthesize(text: text, voice: ttsVoice, rate: playbackRate)
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
            // Read on landing, not at the start: toggling repeat while the
            // synthesis is in flight must still apply.
            let loop = subject == .lookup && repeatEnabled
            do {
                try audioPlayer.play(data: audio.data, loop: loop)
                ttsState = .playing(.audio(looping: loop), subject)
                if subject == .lookup {
                    startReadAlong(with: audio.wordBoundaries)
                }
                logger.info("Audio playback started")
            } catch {
                ttsState = .error(error.localizedDescription, subject)
                logger.error("Failed to play audio: \(error.localizedDescription)")
            }

        case .fallbackUsed(let utteranceGeneration):
            ttsState = .playing(.fallback(generation: utteranceGeneration), subject)
            logger.info("Fallback TTS playback started")

        case .failed(let error):
            ttsState = .error(Self.friendlyTTSMessage(for: error), subject)
            logger.error("TTS synthesis failed: \(error.localizedDescription)")
        }
    }

    /// The text a subject speaks, read when its synthesis starts. A lookup's
    /// cannot change under a live playback: a new session tears playback down
    /// before it replaces `currentText`.
    private func spokenText(for subject: PlaybackSubject) -> String {
        switch subject {
        case .lookup:
            return currentText
        case .oneShot(let text):
            return text
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
    ///
    /// `resetHighlight` is false when resuming: the audio picks up mid-word, and
    /// blanking the emphasis first would flash the text.
    private func startReadAlongTracking(resetHighlight: Bool = true) {
        readAlongTask?.cancel()
        readAlongTask = nil
        if resetHighlight {
            spokenWordIndex = nil
        }
        guard !currentWordBoundaries.isEmpty else { return }

        readAlongTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updateSpokenWordIndex()
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    /// Halts highlight updates while keeping the current word emphasized — the
    /// audio is paused, not finished, so the poll has nothing to do until it
    /// resumes but the highlight must stay where the audio stopped.
    private func suspendReadAlongTracking() {
        readAlongTask?.cancel()
        readAlongTask = nil
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

        // Last word whose start we've passed, found by bisection over the
        // (ascending) boundary times. Resolved from the clock rather than
        // advanced from the previous index, so looped playback — where
        // currentTime wraps back to 0 — re-tracks naturally.
        var low = 0
        var high = currentWordBoundaries.count - 1
        var newIndex: Int?
        while low <= high {
            let middle = low + (high - low) / 2
            if currentWordBoundaries[middle].time <= time {
                newIndex = middle
                low = middle + 1
            } else {
                high = middle - 1
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
        guard case .playing(let source, let subject) = ttsState else { return }
        logger.info("Pausing TTS playback")
        switch source {
        case .fallback:
            Task { await ttsManager.pauseFallback() }
        case .audio:
            audioPlayer.pause()
            suspendReadAlongTracking()
        }
        ttsState = .paused(source, subject)
    }

    func resumeTTS() {
        guard case .paused(let source, let subject) = ttsState else { return }
        logger.info("Resuming TTS playback")
        switch source {
        case .fallback:
            Task { await ttsManager.resumeFallback() }
        case .audio:
            audioPlayer.resume()
            startReadAlongTracking(resetHighlight: false)
        }
        ttsState = .playing(source, subject)
    }

    /// Play/pause for the panel and HUD, which show the lookup. Anything else
    /// playing (a Collection row, the voice preview) reads as idle there, so
    /// this replaces it with the lookup instead of pausing it.
    func togglePlayPause() {
        logger.info("Toggling play/pause")
        switch lookupPlayback {
        case .playing:
            pauseTTS()
        case .paused:
            resumeTTS()
        case .idle, .finished, .error:
            startPlayback(.lookup)
        case .loading:
            return
        }
    }

    func stopTTS() {
        logger.info("Stopping TTS playback")
        playbackGeneration += 1
        playbackTask?.cancel()
        restartPlaybackTask?.cancel()
        restartPlaybackTask = nil
        audioPlayer.stop()
        stopReadAlong()
        ttsState = .idle
        Task { await ttsManager.stopPlayback() }
    }

    /// What closing the panel or HUD silences: the lookup they show, and any
    /// untracked fallback speech. A Collection row or the voice preview
    /// playing meanwhile belongs to another window and keeps playing.
    private func stopLookupPlayback() {
        if case .oneShot? = ttsState.subject { return }
        stopTTS()
    }

    /// Toggles the persistent repeat preference (shared by the panel and the
    /// HUD, and honored by every new playback) and applies it to the loaded
    /// audio in place: enabling mid-play loops seamlessly, disabling lets the
    /// current pass finish instead of cutting it off.
    func toggleLoop() {
        if repeatEnabled {
            logger.info("Repeat turned off")
            repeatEnabled = false
            audioPlayer.setLooping(false)
            setLiveAudioLooping(false)
        } else {
            logger.info("Repeat turned on")
            repeatEnabled = true
            switch ttsState {
            case .playing(.fallback, _), .paused(.fallback, _):
                // Looping replays buffered audio data; fallback speech has none.
                return
            case .playing(.audio, .lookup), .paused(.audio, .lookup):
                audioPlayer.setLooping(true)
                setLiveAudioLooping(true)
            case .loading:
                // A synthesis is in flight; a lookup reads the preference on landing.
                break
            case .finished(.lookup), .error(_, .lookup):
                do {
                    try audioPlayer.replayLooping()
                    ttsState = .playing(.audio(looping: true), .lookup)
                    startReadAlongTracking()
                } catch {
                    ttsState = .error(error.localizedDescription, .lookup)
                    logger.error("Loop failed: \(error.localizedDescription)")
                }
            case .idle,
                 .playing(.audio, .oneShot),
                 .paused(.audio, .oneShot),
                 .finished(.oneShot),
                 .error(_, .oneShot):
                // No lookup audio is loaded to loop: the preference applies to
                // the next lookup playback, and a one shot never loops.
                break
            }
        }
    }

    /// Rewrites the loop flag of live audio playback, keeping play/pause as is.
    private func setLiveAudioLooping(_ looping: Bool) {
        switch ttsState {
        case .playing(.audio, let subject):
            ttsState = .playing(.audio(looping: looping), subject)
        case .paused(.audio, let subject):
            ttsState = .paused(.audio(looping: looping), subject)
        case .idle, .loading, .playing(.fallback, _), .paused(.fallback, _), .finished, .error:
            break
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

        // Restart what is playing, or still synthesizing at the old rate, so
        // the new rate is heard now. Paused audio keeps its place; the new
        // rate applies from its next fresh start.
        switch ttsState {
        case .loading(let subject), .playing(_, let subject):
            // Cancelling stops a synthesis still in flight at the old rate,
            // whichever task owns it, rather than leaving it to finish unheard.
            playbackTask?.cancel()
            restartPlaybackTask?.cancel()
            restartPlaybackTask = Task {
                await restartPlayback(of: subject)
            }
        case .idle, .paused, .finished, .error:
            break
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

    /// Replays the subject that was live when the rate changed. A Collection
    /// row or the voice preview restarts as itself, not as the last lookup.
    private func restartPlayback(of subject: PlaybackSubject) async {
        logger.info("Restarting playback with updated rate")
        await synthesizeAndPlay(subject)
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
                self.stopLookupPlayback()
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
            // Created once and reused across shows: this view hosts the
            // resident Apple Translation session task, and rebuilding it would
            // tear the warm session down — re-paying session startup on every
            // lookup. Content stays current through the observed AppState.
            if panel.contentViewController == nil {
                panel.contentViewController = NSHostingController(rootView: TranslationView(appState: self))
            }
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
        stopLookupPlayback()
        hidePanel()
    }

    // MARK: - Esc While Speaking

    /// Holds the global Esc only while lookup speech is loading or playing in
    /// a visible panel or HUD. Gated on the surface as well as the state so a
    /// stale `ttsState` can never leave Esc swallowed in every other app, and
    /// on the lookup so a Collection row playing behind a pinned panel leaves
    /// Esc alone.
    private func updateSpeechEscapeClaim() {
        let isSurfaceVisible = isPanelVisible || soundOnlyPanel?.isVisible == true
        shortcutManager.setEscapeClaimed(
            lookupPlayback.isPlayingOrLoading && isSurfaceVisible,
            by: .speech
        )
    }

    /// Esc while speaking: silence it and close whichever surface is showing —
    /// the panel even when pinned, as Esc inside the panel already does.
    private func stopSpeakingAndClose() {
        logger.info("Esc pressed while speaking — stopping and closing")
        stopLookupPlayback()
        hidePanel()
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        soundOnlyPanel?.orderOut(nil)
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
            guard hasLookupAudio else { return false }
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
                self.stopLookupPlayback()
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
            self.updateSpeechEscapeClaim()
        }
    }

    /// Called by the HUD's dismiss button.
    func dismissSoundOnlyHUD() {
        logger.info("Dismissing sound only HUD")
        hideSoundOnlyTask?.cancel()
        hideSoundOnlyTask = nil
        stopLookupPlayback()
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
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
        switch lookup {
        case .translated, .dictionary(_, translatingDefinitions: false):
            return true
        case .idle, .loading, .dictionary(_, translatingDefinitions: true), .failed:
            return false
        }
    }

    func toggleSaveCurrentToCollection() {
        guard !currentText.isEmpty else { return }

        if let existing = collectionStore.item(forSourceText: currentText) {
            collectionStore.remove(id: existing.id)
            logger.info("Removed item from collection")
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
    /// Stops any prior playback and does not touch translation state. A one shot
    /// on purpose: repeat applies to lookup playback, where a repeat toggle is
    /// on screen, and Collection rows and previews have none.
    func playCollectionItem(text: String) {
        guard !text.isEmpty else { return }
        startPlayback(.oneShot(text))
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
