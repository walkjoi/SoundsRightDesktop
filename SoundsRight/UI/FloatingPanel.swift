import AppKit

/// Keyboard commands the translation panel understands while it is key.
enum PanelKeyCommand {
    case togglePlayPause
    case toggleLoop
    case toggleSave
    case copyTranslation
    /// 1-based index into `PlaybackRate.allCases` (1 = 0.5x … 5 = 1.5x).
    case setRate(Int)
}

final class FloatingPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

    /// Return true to consume the key; false falls through to the responder chain.
    var onKeyCommand: (@MainActor (PanelKeyCommand) -> Bool)?

    init(contentSize: NSSize = NSSize(width: 460, height: 200), borderless: Bool = false) {
        let styleMask: NSWindow.StyleMask = borderless
            ? [.nonactivatingPanel, .borderless]
            : [.nonactivatingPanel, .titled, .closable, .fullSizeContentView]

        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isMovableByWindowBackground = true
        self.isOpaque = !borderless
        self.backgroundColor = borderless ? .clear : .windowBackgroundColor
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.delegate = self

        if !borderless {
            self.titlebarAppearsTransparent = true
            self.titleVisibility = .hidden
            // No custom contentView here: AppState.showPanel() assigns contentViewController,
            // which replaces the window's contentView wholesale.
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
        self.orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if let command = Self.keyCommand(for: event), onKeyCommand?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Plain-key vocabulary (no modifiers): Space play/pause, L loop, S save,
    /// C copy, 1–5 direct speed. Modified keys fall through so text-selection
    /// shortcuts like ⌘C inside the panel keep working.
    private static func keyCommand(for event: NSEvent) -> PanelKeyCommand? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            return .togglePlayPause
        case "l":
            return .toggleLoop
        case "s":
            return .toggleSave
        case "c":
            return .copyTranslation
        case let digit? where ("1"..."5").contains(digit):
            return .setRate(Int(digit) ?? 1)
        default:
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
