// Accessibility permission (PLAN §2.4, onboarding step 3): needed to post ⌘V and to read the focused element.
//
// Unverified on macOS (written on Linux):
// - The prompt option is passed by its string value ("AXTrustedCheckOptionPrompt") rather than through the
//   kAXTrustedCheckOptionPrompt global, to avoid its Unmanaged/concurrency wrapping; the value is the same.
// - After an ad-hoc-signed rebuild, macOS may show the toggle as on while AXIsProcessTrusted() stays false
//   (a stale entry). The onboarding hint "remove it with − and add it again" uses `revealAppInFinder()`.

import AppKit
import ApplicationServices
import DevshoutCore
import Foundation

public enum AccessibilityPermission {
    /// System Settings → Privacy & Security → Accessibility.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Whether devshout may post events and read other apps' UI.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its "devshout would like to control this computer" prompt (only shown once per app
    /// identity; later calls just return the current state). Returns whether devshout is trusted now.
    @discardableResult
    public static func prompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane of System Settings.
    @MainActor
    @discardableResult
    public static func openSystemSettings() -> Bool {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Shows devshout.app selected in Finder, so it can be dragged into the Accessibility list.
    @MainActor
    public static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Resumes once devshout is trusted (checking now, then every `interval`). Returns false if the task was
    /// cancelled or `timeout` passed first. macOS sends no notification for this, hence the polling.
    public static func waitUntilTrusted(interval: Duration = .seconds(1), timeout: Duration? = nil) async -> Bool {
        await Poller.waitUntil(interval: interval, timeout: timeout) { AXIsProcessTrusted() }
    }
}
