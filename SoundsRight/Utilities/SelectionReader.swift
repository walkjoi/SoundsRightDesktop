import AppKit
import ApplicationServices
import os

struct SelectionReader {
    private static let logger = Logger(subsystem: "com.soundsright.desktop", category: "SelectionReader")

    /// Reads the currently selected text by simulating Cmd+C and checking if the clipboard changed.
    /// Returns nil if no text is selected or Accessibility permission is not granted.
    @MainActor
    static func readSelectedText() async -> String? {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility permission not granted — cannot read selection")
            return nil
        }

        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            logger.warning("Failed to create CGEvents for Cmd+C simulation")
            return nil
        }

        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)

        guard let text = await waitForCopiedText(
            on: pasteboard,
            after: oldChangeCount,
            timeoutNanoseconds: 500_000_000
        ) else {
            logger.debug("Clipboard unchanged after Cmd+C within timeout — no text selected")
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return String(trimmed.prefix(AppConstants.maxInputLength))
    }

    @MainActor
    private static func waitForCopiedText(
        on pasteboard: NSPasteboard,
        after oldChangeCount: Int,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        let pollIntervalNanoseconds: UInt64 = 25_000_000
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if pasteboard.changeCount != oldChangeCount {
                return pasteboard.string(forType: .string)
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return nil
    }

    static func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.info("Accessibility trusted: \(trusted)")
    }
}
