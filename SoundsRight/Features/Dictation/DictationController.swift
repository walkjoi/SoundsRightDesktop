import AppKit
import SwiftUI
import os

/// Owns the dictation flow end to end: hotkey gesture, capture, transcription,
/// insertion, and the HUD that narrates it.
///
/// Kept out of `AppState` deliberately — dictation shares nothing with the
/// lookup pipeline beyond the toast surface, and `AppState` is already the
/// largest type in the app.
@MainActor
final class DictationController: ObservableObject {

    // MARK: - Published State

    @Published private(set) var phase: DictationPhase = .idle
    /// 0...1 input level driving the HUD meter.
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var modelStatus: WhisperModelStatus = .notDownloaded
    /// True when this dictation will also be written to disk (⌃⇧`).
    @Published private(set) var isSavingRecording = false

    // MARK: - App Storage

    @AppStorage("dictationLanguage") var dictationLanguageRaw: String = DictationLanguage.auto.rawValue
    @AppStorage("dictationEngine") var dictationEngineRaw: String = DictationEngine.whisper.rawValue
    @AppStorage("whisperModel") var whisperModelRaw: String = AppConstants.defaultWhisperModel.rawValue

    var language: DictationLanguage {
        DictationLanguage(rawValue: dictationLanguageRaw) ?? .auto
    }

    var preferredEngine: DictationEngine {
        DictationEngine(rawValue: dictationEngineRaw) ?? .whisper
    }

    var modelVariant: WhisperModelVariant {
        WhisperModelVariant(rawValue: whisperModelRaw) ?? AppConstants.defaultWhisperModel
    }

    // MARK: - Services

    private let recorder = DictationRecorder()
    private let manager: DictationManager
    private let recordingStore = DictationRecordingStore()

    /// Shown near the caret while recording and transcribing.
    private var hudPanel: FloatingPanel?

    /// Cursor-anchored feedback, borrowed from AppState so dictation failures
    /// read the same as lookup failures.
    var showToast: (@MainActor (String, ToastView.Style) -> Void)?
    /// Claims Esc only while a dictation is in flight.
    var setCancelShortcutEnabled: (@MainActor (Bool) -> Void)?
    /// Raised when the Accessibility grant is missing, which would leave the
    /// transcript stranded on the clipboard.
    var requestAccessibilityGrant: (@MainActor () -> Void)?

    // MARK: - Gesture State

    /// When the current key press started, for the hold-versus-tap decision.
    private var keyDownAt: ContinuousClock.Instant?
    /// True when the press that is currently down is the one that started
    /// recording. A press that *stopped* a latched recording must not also be
    /// interpreted as a push-to-talk release.
    private var pressStartedRecording = false

    private var transcriptionTask: Task<Void, Never>?
    /// Bumped per activation so a superseded transcription cannot paste.
    private var activationID = 0

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "DictationController")

    // MARK: - Lifecycle

    init() {
        let storedModel = UserDefaults.standard.string(forKey: "whisperModel")
        let variant = storedModel.flatMap(WhisperModelVariant.init(rawValue:)) ?? AppConstants.defaultWhisperModel
        manager = DictationManager(modelVariant: variant)
    }

    func initialize() async {
        recorder.onMeterUpdate = { [weak self] level, elapsed in
            self?.level = level
            self?.elapsed = elapsed
        }
        recorder.onDurationLimitReached = { [weak self] in
            guard let self else { return }
            self.showToast?("Reached the \(Int(AppConstants.dictationMaxDuration / 60))-minute limit — transcribing", .info)
            self.stopAndTranscribe()
        }

        await manager.setModelStatusHandler { [weak self] status in
            self?.modelStatus = status
        }

        // Only start the download when Whisper is actually the chosen engine;
        // a user who picked the built-in engine should never pay 632 MB.
        if preferredEngine == .whisper {
            await manager.warmUpWhisper()
        }

        logger.info("Dictation initialized (engine: \(self.dictationEngineRaw, privacy: .public))")
    }

    func shutdown() async {
        transcriptionTask?.cancel()
        recorder.cancel()
        hidePanel()
        await manager.shutdown()
    }

    // MARK: - Hotkey Gesture

    /// Press-and-hold is push-to-talk; a quick tap latches recording on until
    /// the shortcut is pressed again. Both gestures share one hotkey, so the
    /// user never has to choose a mode.
    func handleKeyDown(saveRecording: Bool) {
        keyDownAt = .now

        if phase == .recording {
            // Second press of a latched recording: finish it, and make sure the
            // matching key-up is not mistaken for a push-to-talk release.
            pressStartedRecording = false
            stopAndTranscribe()
            return
        }

        pressStartedRecording = true
        start(saveRecording: saveRecording)
    }

    func handleKeyUp() {
        defer {
            keyDownAt = nil
            pressStartedRecording = false
        }

        guard phase == .recording, pressStartedRecording, let keyDownAt else { return }

        let held = keyDownAt.duration(to: .now)
        let heldSeconds = TimeInterval(held.components.seconds)
            + Double(held.components.attoseconds) / 1e18

        if heldSeconds >= AppConstants.dictationHoldThreshold {
            stopAndTranscribe()
        }
        // A quick tap leaves the recording latched; the next press ends it.
    }

    /// Menu bar entry — always a plain toggle, since there is no key to hold.
    func toggleFromMenu() {
        if phase == .recording {
            stopAndTranscribe()
        } else {
            start(saveRecording: false)
        }
    }

    func cancel() {
        guard phase.isActive else { return }
        logger.info("Dictation cancelled by the user")
        activationID += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recorder.cancel()
        finishSession()
    }

    // MARK: - Core Actions

    private func start(saveRecording: Bool) {
        guard phase != .recording else { return }

        activationID += 1
        let activation = activationID
        isSavingRecording = saveRecording

        Task { @MainActor in
            guard await DictationRecorder.requestMicrophoneAccess() else {
                self.fail(with: .microphonePermissionDenied)
                return
            }
            // The built-in engine additionally needs the Speech grant; Whisper
            // runs entirely in-process and needs nothing beyond the microphone.
            if self.preferredEngine == .appleOnDevice,
               await AppleSpeechTranscriber.requestSpeechAccess() == false {
                self.fail(with: .speechPermissionDenied)
                return
            }
            guard activation == self.activationID else { return }

            do {
                try self.recorder.start()
            } catch let error as DictationError {
                self.fail(with: error)
                return
            } catch {
                self.fail(with: .recordingFailed(error.localizedDescription))
                return
            }

            self.level = 0
            self.elapsed = 0
            self.phase = .recording
            self.setCancelShortcutEnabled?(true)
            self.showPanel()
        }
    }

    private func stopAndTranscribe() {
        guard phase == .recording else { return }

        phase = .transcribing
        let activation = activationID
        let language = self.language
        let engine = preferredEngine
        let saveRecording = isSavingRecording

        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let audio = await self.recorder.finish()
            guard activation == self.activationID, !Task.isCancelled else { return }

            var transcript: DictationTranscript?
            var failure: DictationError?
            do {
                transcript = try await self.manager.transcribe(
                    audio,
                    language: language,
                    preferredEngine: engine
                )
            } catch is CancellationError {
                return
            } catch let error as DictationError {
                failure = error
            } catch {
                failure = .transcriptionFailed(error.localizedDescription)
            }

            guard activation == self.activationID, !Task.isCancelled else { return }

            // A saved recording is kept even when transcription failed — the
            // audio is the artifact the user asked for.
            if saveRecording, !audio.samples.isEmpty {
                await self.persist(audio: audio, transcript: transcript)
            }

            if let transcript {
                self.deliver(transcript)
            } else if let failure {
                self.fail(with: failure)
            }
        }
    }

    private func deliver(_ transcript: DictationTranscript) {
        logger.info("""
        Dictation ready: \(transcript.text.count, privacy: .public) chars, \
        \(transcript.engine.rawValue, privacy: .public), \
        \(String(format: "%.2f", transcript.processingDuration), privacy: .public)s
        """)

        // The HUD is dismissed first: it is a non-activating panel, but the
        // synthesized ⌘V should land with nothing of ours on screen.
        finishSession()

        switch TextInserter.insert(transcript.text) {
        case .pasted:
            if transcript.engine == .appleOnDevice, preferredEngine == .whisper {
                showToast?("Used the built-in engine — Whisper model still downloading", .notice)
            }
        case .copiedOnly:
            showToast?("Copied to the clipboard — press ⌘V to paste", .notice)
            if !SelectionReader.isAccessibilityGranted {
                requestAccessibilityGrant?()
            }
        }
    }

    private func persist(audio: DictationAudio, transcript: DictationTranscript?) async {
        if let url = await recordingStore.save(audio: audio, transcript: transcript) {
            showToast?("Recording saved — \(url.lastPathComponent)", .info)
        } else {
            showToast?("Couldn't save the recording", .notice)
        }
    }

    /// Every failed activation is visible: a hotkey press must never resolve to
    /// nothing, the same rule the lookup shortcuts follow.
    private func fail(with error: DictationError) {
        logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
        recorder.cancel()
        finishSession()
        showToast?(error.toastMessage, .notice)
    }

    private func finishSession() {
        phase = .idle
        level = 0
        elapsed = 0
        isSavingRecording = false
        setCancelShortcutEnabled?(false)
        hidePanel()
    }

    // MARK: - Settings

    func applyEngineChange() {
        guard preferredEngine == .whisper else { return }
        Task { await manager.warmUpWhisper() }
    }

    func applyModelChange() {
        let variant = modelVariant
        Task {
            await manager.setModelVariant(variant)
            guard preferredEngine == .whisper else { return }
            await manager.warmUpWhisper()
        }
    }

    /// Settings → "Download now", for users who would rather not wait for the
    /// first dictation to trigger the download.
    func downloadModelNow() {
        Task { await manager.warmUpWhisper() }
    }

    func revealSavedRecordings() {
        let directory = DictationRecordingStore.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    var savedRecordingCount: Int { recordingStore.savedCount() }

    // MARK: - HUD

    private func showPanel() {
        if hudPanel == nil {
            hudPanel = FloatingPanel(contentSize: NSSize(width: 200, height: 44), borderless: true)
            hudPanel?.ignoresMouseEvents = true
        }
        guard let panel = hudPanel else { return }

        let hostingView = NSHostingView(rootView: DictationHUD(controller: self))
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFront(nil)
    }

    /// Anchors above the caret when the focused app reports one, so the HUD sits
    /// where the text will land; otherwise above the pointer.
    private func position(_ panel: NSPanel, size: NSSize) {
        let anchor = CaretLocator.inputAnchor() ?? NSEvent.mouseLocation
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 22)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        panel.setFrameOrigin(origin)
    }

    private func hidePanel() {
        hudPanel?.orderOut(nil)
    }
}
