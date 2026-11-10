import AppKit
import SwiftUI

/// What SwiftUI's App can't do on its own: start the coordinator once AppKit is up, keep running with no windows,
/// and open Settings when the app is opened again from Finder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon (also set by LSUIElement; SettingsOpener raises it while Settings is open).
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

/// Makes the 1×1 window that hosts `SettingsOpenerView` invisible and inert: transparent, click-through, off
/// screen, out of the window cycle and Mission Control. It stays open, because the opener view must stay alive.
struct HiddenWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        HidingView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1, height: 1), display: false)
            if window.isKeyWindow { window.resignKey() }
        }
    }
}
