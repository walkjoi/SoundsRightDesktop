import Carbon.HIToolbox
import CoreGraphics

/// Resolves virtual key codes against the *active* keyboard layout.
///
/// Hardcoding `kVK_ANSI_C` would send ⌘J on Dvorak, and ⌘V would land somewhere
/// else again. The Command modifier has to be part of the lookup: "Dvorak —
/// QWERTY ⌘" layouts remap letters only while Command is held.
enum KeyboardLayout {

    /// The key that produces `character` with Command held, or `fallback` when
    /// the layout cannot be read (non-Latin layouts, where QWERTY positions are
    /// what the system uses for shortcuts anyway).
    static func commandKeyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
        guard let lowercase = character.lowercased().unicodeScalars.first?.value,
              let uppercase = character.uppercased().unicodeScalars.first?.value,
              let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallback
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        let commandModifiers = UInt32((cmdKey >> 8) & 0xFF)

        for keyCode in 0..<CGKeyCode(128) {
            var deadKeyState: UInt32 = 0
            var actualLength = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(-1)
                }
                return UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    commandModifiers,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &actualLength,
                    &characters
                )
            }

            if status == noErr, actualLength == 1,
               UInt32(characters[0]) == lowercase || UInt32(characters[0]) == uppercase {
                return keyCode
            }
        }

        return fallback
    }

    /// Posts a Command-modified keystroke through the HID event tap.
    /// Returns false when the events could not be created.
    @discardableResult
    static func postCommandKeystroke(keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
