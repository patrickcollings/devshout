// Delivers the final text (PLAN §3.3): clipboard first, then ⌘V into whatever has focus at paste time.
// Decision 8: the previous clipboard is never restored, so nothing can race the target app reading it.
//
// Unverified on macOS (written on Linux):
// - The event source and suppression filter follow what clipboard managers such as Maccy do; posting at
//   .cghidEventTap needs Accessibility trust, which is checked first.
// - Explicit .maskCommand flags should override a modifier the user is still physically holding (⌥ from ⌥Space).
// - The 30 ms settle delay comes from the plan; raise it if an app pastes the previous clipboard.
// - Secure input: the brief said to skip ⌘V whenever IsSecureEventInputEnabled(); because it is system-wide,
//   devshout only skips when the focused element is a password field or can't be read (PastePreflight).
//   Assumed: a posted ⌘V still reaches an ordinary text field while another app holds secure input.
// - IsSecureEventInputEnabled is assumed to import as Bool (compared with `== true`, which also builds if it is
//   DarwinBoolean).

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DevshoutCore
import Foundation

/// Writes plain text to the general pasteboard and checks it took.
public enum PasteboardWriter {
    /// Clears the pasteboard and sets `text` as a string, retrying once if `changeCount` didn't advance or the
    /// text doesn't read back. Returns whether it ended up on the clipboard.
    @MainActor
    @discardableResult
    public static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        for _ in 0..<2 {
            let before = pasteboard.changeCount
            pasteboard.clearContents()
            let wrote = pasteboard.setString(text, forType: .string)
            if wrote, pasteboard.changeCount != before, pasteboard.string(forType: .string) == text {
                return true
            }
        }
        return false
    }
}

/// Whether Secure Event Input is on. It is system-wide: a password field anywhere, or an app such as Terminal with
/// Secure Keyboard Entry, turns it on. See `PastePreflight.skipReason` for how the paste uses it.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() == true }
}

/// The `Deliverer` for the app: clipboard plus ⌘V (or Accessibility insert), never a newline, never restoring
/// the old clipboard.
public struct Paster: Deliverer {
    /// Settings → General → Paste method.
    public enum Method: String, Sendable, CaseIterable, Hashable, Codable {
        /// Post ⌘V with CGEvent (the default).
        case commandV
        /// Set the focused element's selected text through Accessibility, for apps that ignore synthetic ⌘V.
        /// Falls back to ⌘V when the app refuses.
        case accessibility
    }

    private let method: @Sendable () -> Method
    private let settleDelay: Duration

    /// - Parameter method: read at each delivery, so a settings change applies straight away.
    public init(method: @escaping @Sendable () -> Method = { .commandV }, settleDelay: Duration = .milliseconds(30)) {
        self.method = method
        self.settleDelay = settleDelay
    }

    public func deliver(_ text: String) async -> DeliveryOutcome {
        // Never add or keep a trailing newline: nothing should auto-submit in a terminal or chat box.
        let text = PastePreflight.textToDeliver(text)
        guard !text.isEmpty else { return .failed(reason: Self.nothingToPasteReason) }

        let copied = await MainActor.run { () -> Bool in
            if PasteboardWriter.copy(text) { return true }
            // Don't leave the previous contents there for a ⌘V the user might press: clear it instead.
            NSPasteboard.general.clearContents()
            return false
        }
        guard copied else { return .failed(reason: Self.clipboardFailedReason) }

        let target = await MainActor.run { () -> (pid: pid_t?, name: String?, isSelf: Bool) in
            let app = NSWorkspace.shared.frontmostApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            return (app?.processIdentifier, app?.localizedName, isSelf)
        }

        let trusted = AXIsProcessTrusted()
        // Accessibility reads need trust, and are pointless when devshout itself is in front.
        let focused = trusted && !target.isSelf ? FocusedElement.info(inProcess: target.pid) : nil
        let conditions = PastePreflight.Conditions(accessibilityTrusted: trusted,
                                                   secureInputEnabled: SecureInput.isEnabled,
                                                   devshoutFrontmost: target.isSelf,
                                                   focused: focused)
        if let reason = PastePreflight.skipReason(conditions) {
            return .copiedOnly(reason: reason.message)
        }

        if method() == .accessibility, FocusedElement.insert(text, inProcess: target.pid) {
            return .pasted(appName: target.name)
        }

        try? await Task.sleep(for: settleDelay)
        let posted = await MainActor.run { Self.postCommandV() }
        guard posted else { return .copiedOnly(reason: "Couldn't send ⌘V") }
        return .pasted(appName: target.name)
    }

    // Reasons for `.failed`: the text is NOT on the clipboard.
    public static let nothingToPasteReason = "Nothing copied: there was no text"
    public static let clipboardFailedReason = "Nothing copied: the clipboard didn't take the text"

    /// Posts ⌘V (key down, key up) at the HID event tap, using the key that types "v" in the current layout.
    @MainActor
    static func postCommandV() -> Bool {
        let keyCode = KeyboardLayout.keyCode(for: "v")
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
