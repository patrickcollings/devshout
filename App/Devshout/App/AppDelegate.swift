import AppKit
import SwiftUI

/// What SwiftUI's App can't do on its own: start the coordinator once AppKit is up, keep running with no windows,
/// and open Settings when the app is opened again from Finder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon (also set by LSUIElement; a Dock icon appears only while Settings is open).
        NSApp.setActivationPolicy(.accessory)
        AppCoordinator.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Double-clicking devshout.app while it's running opens Settings (there is no Dock icon to click).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.openSettings()
        return false
    }
}
