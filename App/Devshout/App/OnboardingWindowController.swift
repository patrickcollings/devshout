import AppKit
import SwiftUI

/// The onboarding window (about 640×480, fixed size). Shown at first launch and from "Set Up devshout…" /
/// Settings → General; call `OnboardingViewModel.restart()` before `show()` to start from the beginning.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingViewModel
    private var window: NSWindow?

    init(model: OnboardingViewModel) {
        self.model = model
        super.init()
    }

    /// The onboarding window is in front and devshout is active (so a dictation's paste lands in its Try it box).
    var isFrontmost: Bool {
        guard let window else { return false }
        return window.isVisible && window.isKeyWindow && NSApp.isActive
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // An LSUIElement app's windows open behind the frontmost app unless it activates.
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        model.windowDidAppear()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Stop the level meter and any pending auto-advance (SwiftUI's onDisappear may not run for a closed window).
        model.windowDidDisappear()
        // Back to a pure menu bar app unless Settings is still open.
        let others = NSApp.windows.filter { other in
            other !== window && other.isVisible && other.alphaValue > 0 && other.styleMask.contains(.titled)
        }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to devshout"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }
}
