import AppKit
import ApplicationServices
import os

/// Finds where typed text will appear, so the dictation HUD can sit next to the
/// caret instead of wherever the mouse happens to be.
enum CaretLocator {

    private static let logger = Logger(subsystem: "com.soundsright.desktop", category: "CaretLocator")

    /// Every AX call is a synchronous IPC round-trip with a six-second default
    /// timeout. A busy target app would otherwise stall the HUD for seconds.
    private static let messagingTimeout: Float = 0.2

    /// Caret position in Cocoa coordinates, or nil when the focused app does not
    /// report one. Callers fall back to the pointer.
    static func inputAnchor() -> NSPoint? {
        guard AXIsProcessTrusted(), let primaryScreen = NSScreen.screens.first else { return nil }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        guard let caretRect = caretRect(for: element) else { return nil }

        // AX reports y growing downward from the top of the primary screen;
        // Cocoa grows upward from its bottom.
        let point = NSPoint(
            x: caretRect.minX,
            y: primaryScreen.frame.maxY - caretRect.maxY
        )

        // A rect that maps outside every display is a placeholder, not a caret.
        guard NSScreen.screens.contains(where: { $0.frame.contains(point) }) else {
            logger.debug("Caret resolved outside every screen — ignoring")
            return nil
        }
        return point
    }

    private static func caretRect(for element: AXUIElement) -> CGRect? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        ) == .success, let rangeValue = selectedRange else {
            return nil
        }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &bounds
        ) == .success, let boundsValue = bounds, CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(boundsValue, to: AXValue.self), .cgRect, &rect) else { return nil }

        // Many apps return .success with a degenerate rect when they do not
        // actually know: all zeros in Electron, or a zero-size rect pinned to a
        // screen corner in Terminal. A real caret always has a line height.
        guard rect.height > 0 else { return nil }
        return rect
    }
}
