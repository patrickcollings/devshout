import AppKit
import SwiftUI

/// The Settings window. An AppKit window rather than SwiftUI's `Settings` scene: opening that scene from a menu
/// bar (LSUIElement) app needs a live SwiftUI view to call `openSettings`, and the hidden helper window that
/// provided one fought SwiftUI's layout and could crash the app at launch.
///
/// While the window is open devshout has a Dock icon, so the window can be found again with ⌘-Tab.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let models: DevshoutViewModels
    private var window: NSWindow?

    init(models: DevshoutViewModels) {
        self.models = models
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            window.contentViewController = NSHostingController(rootView: SettingsView(models: models))
        }
        // An LSUIElement app's windows open behind the frontmost app unless it activates.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu bar app unless onboarding is still open.
        let others = NSApp.windows.filter { other in
            other !== window && other.isVisible && other.alphaValue > 0 && other.styleMask.contains(.titled)
        }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
        // The Transcription tab's level meter keeps the microphone open: stop it whatever SwiftUI reports.
        models.microphone.stopLevelMonitoring(for: .settings)
        // Likewise a recording playing in the History tab: it has no window left to be stopped from.
        models.history.stopPlayback()
        // Drop the SwiftUI views once the window has gone, so their `onDisappear` runs (it stops the microphone
        // level meter) and the next `show()` starts afresh.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "devshout Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }
}
