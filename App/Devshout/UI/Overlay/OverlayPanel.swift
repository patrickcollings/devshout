// The floating panel that hosts RecordingPill: non-activating (it never takes focus, so the paste target stays put),
// never key or main, floating above other windows, on every Space and over full-screen apps, positioned
// bottom-centre (above the Dock) on the screen that has the mouse.
//
//     let panel = OverlayPanel(model: models.pill)
//     models.pill.begin(mode: .tidy); panel.present()
//     … models.pill.phase = .done(.pasted(appName: "Slack")); panel.dismiss(after: 1.2)
//
// Unsure on macOS (not compiled here):
// - Subclassing NSPanel with only a custom designated init (no `init?(coder:)`); this is the usual pattern and
//   NSWindow doesn't require the coder init.
// - Subclassing `NSHostingView` to override `acceptsFirstMouse(for:)` (so the first click on Stop/Cancel works
//   without activating anything). It is a non-generic subclass on purpose (see its comment). If it causes
//   trouble, drop `FirstClickHostingView` and use NSHostingView directly.
// - Clicks in the transparent margin around the pill: with a clear, non-opaque window they should fall through to
//   the window below; if not, the margin is small.

import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    /// Room for the pill (two lines at most) and its shadow.
    static let panelSize = NSSize(width: RecordingPill.width + 40, height: 120)
    /// Gap between the pill and the bottom of the visible frame (the top of the Dock).
    static let bottomMargin: CGFloat = 14

    let pillModel: RecordingPillViewModel
    private var hideTask: Task<Void, Never>?

    init(model: RecordingPillViewModel) {
        self.pillModel = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // SwiftUI draws the pill's shadow.
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true

        let hosting = FirstClickHostingView(rootView: OverlayRootView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]

        let container = HoverTrackingView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onHoverChange = { [weak model] hovering in model?.isHovering = hovering }
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the pill (fading in if hidden) on the screen with the mouse, or on `screen`.
    func present(on screen: NSScreen? = nil) {
        hideTask?.cancel()
        hideTask = nil
        moveToBottomCentre(of: screen ?? Self.screenWithMouse() ?? NSScreen.main)
        if isVisible {
            // Possibly mid fade-out: animate back up so the running fade can't leave it at 0.
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                self.animator().alphaValue = 1
            }
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1
        }
    }

    /// Fade out and hide, after `delay` seconds (e.g. 1.2 for "Pasted into Slack"). A `present()` in the
    /// meantime cancels it.
    func dismiss(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 0
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.pillModel.isHovering = false
            self.hideTask = nil
        }
    }

    func moveToBottomCentre(of screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: (visible.midX - frame.width / 2).rounded(),
                             y: (visible.minY + Self.bottomMargin).rounded())
        setFrameOrigin(origin)
    }

    static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

/// Pins the pill to the bottom of the panel, with room above for the second line and around for the shadow.
private struct OverlayRootView: View {
    @ObservedObject var model: RecordingPillViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            RecordingPill(model: model)
        }
        .padding(.bottom, 12)
        .frame(width: OverlayPanel.panelSize.width, height: OverlayPanel.panelSize.height)
    }
}

/// Lets the first click land on a button even though the panel is never key. Deliberately not generic: a generic
/// NSHostingView subclass has been reported to crash the Xcode 26 optimiser in release builds.
private final class FirstClickHostingView: NSHostingView<OverlayRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports the mouse entering and leaving the panel, whether or not devshout is active (SwiftUI's `.onHover`
/// may only fire in the key window).
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
