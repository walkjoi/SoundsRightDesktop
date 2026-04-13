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
}

final class ShortcutManager: ObservableObject {
    @Published var isRegistered: Bool = false

    private var onTranslate: (() -> Void)?
    private var onSoundOnly: (() -> Void)?

    func register(onTranslate: @escaping () -> Void, onSoundOnly: @escaping () -> Void) {
        self.onTranslate = onTranslate
        self.onSoundOnly = onSoundOnly

        KeyboardShortcuts.onKeyUp(for: .translateClipboard) { [weak self] in
            self?.onTranslate?()
        }

        KeyboardShortcuts.onKeyUp(for: .soundOnlyClipboard) { [weak self] in
            self?.onSoundOnly?()
        }

        isRegistered = true
    }

    func unregister() {
        KeyboardShortcuts.disable(.translateClipboard)
        KeyboardShortcuts.disable(.soundOnlyClipboard)
        onTranslate = nil
        onSoundOnly = nil
        isRegistered = false
    }
}
