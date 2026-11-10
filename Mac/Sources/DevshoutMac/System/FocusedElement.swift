// Reads (and, for the Accessibility paste method, writes) the focused UI element through the AX API.
//
// Unverified on macOS (written on Linux):
// - Electron and Chromium apps often report no focused element unless their accessibility tree is switched on;
//   that reads as "unknown", and devshout pastes anyway.
// - The 0.25 s messaging timeout is a guess: long enough for slow apps, short enough not to hold up the paste.
// - AXUIElementSetAttributeValue(kAXSelectedTextAttribute) returns .success in some apps without inserting.

import ApplicationServices
import DevshoutCore
import Foundation

enum FocusedElement {
    private static let messagingTimeout: Float = 0.25

    /// The focused element of the frontmost app (`pid`), or system-wide when that fails.
    static func focused(inProcess pid: pid_t?) -> AXUIElement? {
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if let element = copyElement(app, kAXFocusedUIElementAttribute) { return element }
        }
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        return copyElement(systemWide, kAXFocusedUIElementAttribute)
    }

    /// What can be read about the focused element; nil when there is none or it can't be read.
    static func info(inProcess pid: pid_t?) -> FocusedElementInfo? {
        guard let element = focused(inProcess: pid) else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return FocusedElementInfo(role: stringAttribute(element, kAXRoleAttribute),
                                  subrole: stringAttribute(element, kAXSubroleAttribute),
                                  valueSettable: isSettable(element, kAXValueAttribute),
                                  selectedTextSettable: isSettable(element, kAXSelectedTextAttribute))
    }

    /// Replaces the selection (or inserts at the caret) in the focused element. False when the app refused.
    static func insert(_ text: String, inProcess pid: pid_t?) -> Bool {
        guard let element = focused(inProcess: pid) else { return false }
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }
}
