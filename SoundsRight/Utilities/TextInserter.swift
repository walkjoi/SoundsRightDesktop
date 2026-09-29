import AppKit
import Carbon.HIToolbox
import os

/// Types transcribed text into whatever app has focus.
///
/// macOS offers no public API to insert text into another app's field, so this
/// takes the same route every dictation tool does: put the text on the
/// pasteboard, synthesize ⌘V, then put the user's clipboard back.
enum TextInserter {

    private static let logger = Logger(subsystem: "com.soundsright.desktop", category: "TextInserter")

    enum InsertionResult {
        /// Pasted into the focused app; the clipboard will be restored shortly.
        case pasted
        /// Left on the clipboard for the user to paste, because we could not
        /// synthesize the keystroke.
        case copiedOnly
    }

    /// Pastes `text` at the caret. Requires the Accessibility grant that the
    /// lookup shortcuts already depend on.
    @MainActor
    @discardableResult
    static func insert(_ text: String) -> InsertionResult {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        let keyCode = KeyboardLayout.commandKeyCode(for: "v", fallback: CGKeyCode(kVK_ANSI_V))
        guard AXIsProcessTrusted(), KeyboardLayout.postCommandKeystroke(keyCode: keyCode) else {
            logger.warning("Could not synthesize Cmd+V — leaving the transcript on the clipboard")
            return .copiedOnly
        }

        scheduleClipboardRestore(saved, expectedChangeCount: changeCountAfterWrite)
        return .pasted
    }

    /// Restores the previous clipboard, but only after the target app has had a
    /// chance to service the paste. Browsers and Electron apps read the
    /// pasteboard well after the ⌘V event is posted, and restoring earlier makes
    /// them paste the *old* contents instead of the transcript.
    @MainActor
    private static func scheduleClipboardRestore(_ items: [NSPasteboardItem], expectedChangeCount: Int) {
        guard !items.isEmpty else { return }

        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(AppConstants.dictationClipboardRestoreDelay * 1_000_000_000)
            )
            let pasteboard = NSPasteboard.general
            // A different change count means the user (or another app) took the
            // clipboard over in the meantime; restoring would clobber their data.
            guard pasteboard.changeCount == expectedChangeCount else {
                logger.debug("Clipboard changed during the paste window — not restoring")
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
    }

    /// Detached copies of every item: items still attached to the pasteboard are
    /// invalidated by `clearContents` and cannot be written back.
    @MainActor
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
