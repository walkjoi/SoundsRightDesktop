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

            // Vibrancy background for the titled translation panel
            let effect = NSVisualEffectView()
            effect.material = .windowBackground
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            self.contentView = effect
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
