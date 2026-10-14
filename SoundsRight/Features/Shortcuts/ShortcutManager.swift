import Combine
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let translateClipboard = Self(
        "translateClipboard",
        default: .init(.x, modifiers: [.command, .option])
    )
    static let soundOnlyClipboard = Self(
        "soundOnlyClipboard",
        default: .init(.z, modifiers: [.command, .option])
    )
    /// Dictation. ⌃` sits under the left hand and collides with almost nothing.
    static let dictation = Self(
        "dictation",
        default: .init(.backtick, modifiers: [.control])
    )
    /// Same dictation flow, but the audio is also written to disk.
    static let dictationSaveRecording = Self(
        "dictationSaveRecording",
        default: .init(.backtick, modifiers: [.control, .shift])
    )
    /// Esc: discards an in-flight dictation, or stops speech and closes its
    /// window. Registered globally but only *enabled* while something claims
    /// it, so Esc keeps its normal meaning the rest of the time.
    static let cancel = Self(
        "cancel",
        default: .init(.escape)
    )
}

final class ShortcutManager: ObservableObject {
    /// Callbacks for every global shortcut the app owns. Dictation needs both
    /// edges of the key press: holding it is push-to-talk, tapping it latches.
    struct Handlers {
        let onTranslate: () -> Void
        let onSoundOnly: () -> Void
        let onDictationKeyDown: (_ saveRecording: Bool) -> Void
        let onDictationKeyUp: () -> Void
        let onDictationCancel: () -> Void
        let onStopSpeech: () -> Void
    }

    /// The flows that can hold Esc. KeyboardShortcuts registers hotkeys per key
    /// combination rather than per name, so two names bound to Esc would fire
    /// together and disabling one would unregister both — hence one name, and
    /// the owners tracked here.
    enum EscapeClaim {
        case dictation
        case speech
    }

    @Published var isRegistered: Bool = false

    private var handlers: Handlers?
    private var escapeClaims: Set<EscapeClaim> = []

    func register(_ handlers: Handlers) {
        self.handlers = handlers

        KeyboardShortcuts.onKeyUp(for: .translateClipboard) { [weak self] in
            self?.handlers?.onTranslate()
        }

        KeyboardShortcuts.onKeyUp(for: .soundOnlyClipboard) { [weak self] in
            self?.handlers?.onSoundOnly()
        }

        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            self?.handlers?.onDictationKeyDown(false)
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            self?.handlers?.onDictationKeyUp()
        }

        KeyboardShortcuts.onKeyDown(for: .dictationSaveRecording) { [weak self] in
            self?.handlers?.onDictationKeyDown(true)
        }
        KeyboardShortcuts.onKeyUp(for: .dictationSaveRecording) { [weak self] in
            self?.handlers?.onDictationKeyUp()
        }

        KeyboardShortcuts.onKeyDown(for: .cancel) { [weak self] in
            self?.handleEscape()
        }
        // Esc must not be swallowed except while a claim is held.
        KeyboardShortcuts.disable(.cancel)

        isRegistered = true
    }

    /// Claims Esc for `owner` while `claimed`, and hands it back to the system
    /// once no owner holds it.
    func setEscapeClaimed(_ claimed: Bool, by owner: EscapeClaim) {
        let wasClaimed = !escapeClaims.isEmpty
        if claimed {
            escapeClaims.insert(owner)
        } else {
            escapeClaims.remove(owner)
        }

        let isClaimed = !escapeClaims.isEmpty
        guard isClaimed != wasClaimed else { return }
        if isClaimed {
            KeyboardShortcuts.enable(.cancel)
        } else {
            KeyboardShortcuts.disable(.cancel)
        }
    }

    /// One press ends one thing; when both are live, the dictation goes first.
    private func handleEscape() {
        if escapeClaims.contains(.dictation) {
            handlers?.onDictationCancel()
        } else if escapeClaims.contains(.speech) {
            handlers?.onStopSpeech()
        }
    }

    func unregister() {
        KeyboardShortcuts.disable(
            .translateClipboard,
            .soundOnlyClipboard,
            .dictation,
            .dictationSaveRecording,
            .cancel
        )
        escapeClaims.removeAll()
        handlers = nil
        isRegistered = false
    }
}
