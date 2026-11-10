// The key code that types a letter in the current keyboard layout, so ⌘V works on Dvorak, AZERTY and others.
// The UCKeyTranslate call follows KeyboardShortcuts' own Shortcut.keyToCharacter().
//
// Unverified on macOS (written on Linux):
// - Translating with the ⌘ modifier state first, so "Dvorak – QWERTY ⌘" (which switches to QWERTY while ⌘ is
//   held) gets kVK_ANSI_V. Falls back to translating without modifiers.
// - Non-Latin layouts (Russian, Greek…) have no "v"; the ASCII-capable layout is tried next (Cocoa matches key
//   equivalents against it), then kVK_ANSI_V.

import Carbon.HIToolbox
import CoreGraphics
import DevshoutCore
import Foundation

enum KeyboardLayout {
    /// The virtual key code that types `character` in the current layout; kVK_ANSI_V if none does.
    /// Main actor only: TISGetInputSourceProperty crashes off the main thread.
    @MainActor
    static func keyCode(for character: Character = "v") -> CGKeyCode {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let code = keyCode(for: character, in: source) {
            return code
        }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let code = keyCode(for: character, in: source) {
            return code
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    @MainActor
    private static func keyCode(for character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return withExtendedLifetime(source) { () -> CGKeyCode? in
            let layoutData = unsafeBitCast(rawData, to: CFData.self)
            guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
            let layout = unsafeBitCast(bytes, to: UnsafePointer<UCKeyboardLayout>.self)
            let keyboardType = UInt32(LMGetKbdType())
            let commandState = UInt32((cmdKey >> 8) & 0xFF)

            func translate(_ code: UInt16, modifiers: UInt32) -> String? {
                var deadKeyState: UInt32 = 0
                let maxLength = 4
                var length = 0
                var characters = [UniChar](repeating: 0, count: maxLength)
                let status = UCKeyTranslate(
                    layout,
                    code,
                    UInt16(kUCKeyActionDown),
                    modifiers,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    maxLength,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }

            let preferred = UInt16(kVK_ANSI_V)
            for modifiers in [commandState, 0] {
                if let code = KeyCodeSearch.keyCode(producing: character, preferred: preferred,
                                                    translate: { translate($0, modifiers: modifiers) }) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
