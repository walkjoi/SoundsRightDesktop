import Foundation
import AppKit

struct ClipboardMonitor {
    static func readText() -> String? {
        let pasteboard = NSPasteboard.general
        let types = [NSPasteboard.PasteboardType.string]

        guard pasteboard.availableType(from: types) != nil else {
            return nil
        }

        guard let text = pasteboard.string(forType: .string) else {
            return nil
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            return nil
        }

        let truncatedText = String(trimmedText.prefix(AppConstants.maxInputLength))

        return truncatedText
    }
}
