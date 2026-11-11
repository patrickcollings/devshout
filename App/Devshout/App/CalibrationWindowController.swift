import AppKit
import SwiftUI

/// The "Calibrate Your Voice" window (fixed size). An AppKit window hosting SwiftUI, like Settings and onboarding,
/// and for the same reason: a menu bar app can't open SwiftUI window scenes reliably.
///
/// While it is open devshout has a Dock icon. Closing it is what releases the microphone and stops an analysis:
/// `onClose` runs from `windowWillClose`, never from a SwiftUI `onDisappear`.
@MainActor
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private let model: CalibrationViewModel
    private var window: NSWindow?
    /// The window is closing (red button, Done, Close): stop recording and analysing, and tidy up.
    var onClose: (() -> Void)?

    init(model: CalibrationViewModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            window.contentViewController = NSHostingController(rootView: CalibrationView(model: model))
            window.setContentSize(NSSize(width: CalibrationView.size.width, height: CalibrationView.size.height))
        }
        // An LSUIElement app's windows open behind the frontmost app unless it activates.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        // Back to a pure menu bar app unless Settings or onboarding is still open.
        let others = NSApp.windows.filter { other in
            other !== window && other.isVisible && other.alphaValue > 0 && other.styleMask.contains(.titled)
        }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
        // Drop the SwiftUI views once the window has gone, so the next `show()` starts afresh.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = CalibrationCopy.windowTitle
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }
}
