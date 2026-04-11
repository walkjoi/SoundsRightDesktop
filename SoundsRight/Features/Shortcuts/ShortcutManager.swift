import Combine
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let translateClipboard = Self(
        "translateClipboard",
        default: .init(.z, modifiers: [.option])
    )
}

final class ShortcutManager: ObservableObject {
    @Published var isRegistered: Bool = false

    private var onTrigger: (() -> Void)?

    func register(action: @escaping () -> Void) {
        onTrigger = action

        KeyboardShortcuts.onKeyUp(for: .translateClipboard) { [weak self] in
            self?.onTrigger?()
        }

        isRegistered = true
    }

    func unregister() {
        KeyboardShortcuts.disable(.translateClipboard)
        onTrigger = nil
        isRegistered = false
    }
}
