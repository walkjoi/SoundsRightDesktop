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
    /// Discards the in-flight dictation. Registered globally but only *enabled*
    /// while recording, so Esc keeps its normal meaning the rest of the time.
    static let dictationCancel = Self(
        "dictationCancel",
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
    }

    @Published var isRegistered: Bool = false

    private var handlers: Handlers?

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

        KeyboardShortcuts.onKeyDown(for: .dictationCancel) { [weak self] in
            self?.handlers?.onDictationCancel()
        }
        // Esc must not be swallowed except while a dictation is in flight.
        KeyboardShortcuts.disable(.dictationCancel)

        isRegistered = true
    }

    /// Claims Esc for the duration of a recording, and hands it back after.
    func setDictationCancelEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.dictationCancel)
        } else {
            KeyboardShortcuts.disable(.dictationCancel)
        }
    }

    func unregister() {
        KeyboardShortcuts.disable(
            .translateClipboard,
            .soundOnlyClipboard,
            .dictation,
            .dictationSaveRecording,
            .dictationCancel
        )
        handlers = nil
        isRegistered = false
    }
}
