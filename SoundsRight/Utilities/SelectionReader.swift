import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

struct SelectionReader {
    private static let logger = Logger(subsystem: "com.soundsright.desktop", category: "SelectionReader")

    /// A captured selection. `wasTruncated` is true when the original selection
    /// exceeded `AppConstants.maxInputLength` so callers can tell the user.
    struct Selection {
        let text: String
        let wasTruncated: Bool
    }

    enum SelectionError: LocalizedError {
        case noPermission
        case eventCreationFailed
        case noSelection
        case readInProgress

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Accessibility permission is required to read the selected text."
            case .eventCreationFailed:
                return "Could not synthesize the copy keystroke."
            case .noSelection:
                return "No text selected."
            case .readInProgress:
                return "A selection read is already in progress."
            }
        }
    }

    /// Serializes the snapshot → Cmd+C → poll → restore protocol: an overlapping reader
    /// would snapshot the first reader's copied selection as "the user's clipboard".
    @MainActor
    private static var isReading = false

    /// Reads the currently selected text by simulating Cmd+C and checking if the clipboard changed.
    /// The user's previous clipboard contents are restored afterwards.
    @MainActor
    static func readSelectedText() async -> Result<Selection, SelectionError> {
        guard !isReading else {
            return .failure(.readInProgress)
        }
        isReading = true
        defer { isReading = false }

        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility permission not granted — cannot read selection")
            return .failure(.noPermission)
        }

        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount
        let savedItems = snapshot(of: pasteboard)

        let keyCode = KeyboardLayout.commandKeyCode(for: "c", fallback: CGKeyCode(kVK_ANSI_C))
        guard KeyboardLayout.postCommandKeystroke(keyCode: keyCode) else {
            logger.warning("Failed to create CGEvents for Cmd+C simulation")
            return .failure(.eventCreationFailed)
        }

        guard let text = await waitForCopiedText(
            on: pasteboard,
            after: oldChangeCount,
            timeoutNanoseconds: AppConstants.pasteboardCopyTimeoutNanoseconds
        ) else {
            // Timeout: the pasteboard was never touched, so there is nothing to restore.
            logger.debug("Clipboard unchanged after Cmd+C within timeout — no text selected")
            return .failure(.noSelection)
        }

        // Put the user's clipboard back, unless something newer landed in the meantime.
        restore(savedItems, to: pasteboard, ifChangeCountStill: pasteboard.changeCount)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noSelection) }

        return .success(Selection(
            text: String(trimmed.prefix(AppConstants.maxInputLength)),
            wasTruncated: trimmed.count > AppConstants.maxInputLength
        ))
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

    // MARK: - Clipboard Preservation

    /// Copies every item's data into detached `NSPasteboardItem`s — items still attached
    /// to the pasteboard are invalidated by `clearContents` and cannot be re-written.
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

    @MainActor
    private static func restore(
        _ items: [NSPasteboardItem],
        to pasteboard: NSPasteboard,
        ifChangeCountStill changeCount: Int
    ) {
        guard !items.isEmpty, pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    // MARK: - Permission

    /// Current state of the Accessibility grant, without prompting.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func ensureAccessibilityPermission() {
        // Literal key string instead of kAXTrustedCheckOptionPrompt: the imported
        // global is a `var`, which strict concurrency rejects as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.info("Accessibility trusted: \(trusted)")
    }
}
