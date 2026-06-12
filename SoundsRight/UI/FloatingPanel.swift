import AppKit

final class FloatingPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

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

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
