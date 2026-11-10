// Opening the Settings scene from a menu-style MenuBarExtra is unreliable on macOS 14+: `SettingsLink` and
// `openSettings` need a live SwiftUI window, and an LSUIElement app's windows open behind other apps. The known
// workaround (https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items):
//
// 1. The menu posts `.devshoutOpenSettings` (MenuBarViewModel's default `openSettings` action does this).
// 2. `SettingsOpenerView`, in a tiny hidden `Window` scene declared *before* the `Settings` scene, receives it,
//    briefly gives devshout a Dock icon so its window can come to the front, calls `openSettings()`, and brings the
//    window forward.
// 3. `SettingsView` posts `.devshoutSettingsClosed` on disappear, and the opener drops the Dock icon again.
//
//     var body: some Scene {
//         Window("devshout", id: SettingsOpenerView.windowID) { SettingsOpenerView() }
//             .windowResizability(.contentSize)
//             .defaultSize(width: 1, height: 1)
//         MenuBarExtra { … } label: { … }
//         Settings { SettingsView(models: models) }
//     }
//
// Wiring still has to keep that hidden window off-screen/invisible (e.g. alpha 0, ignoresMouseEvents) at launch.
//
// Unsure on macOS (not compiled here): all of the above is a workaround for SwiftUI behaviour, and the delays are
// empirical. If wiring finds a simpler way on macOS 14/15, MenuBarViewModel.Actions.openSettings can do that instead.

import AppKit
import Combine
import SwiftUI

struct SettingsOpenerView: View {
    static let windowID = "settings-opener"

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .devshoutOpenSettings)) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.regular)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    NSApp.activate()
                    openSettings()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if let window = SettingsWindowFinder.settingsWindow() {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .devshoutSettingsClosed)) { _ in
                // Back to a menu bar app, unless another of our windows (onboarding) is still open.
                let settings = SettingsWindowFinder.settingsWindow()
                let others = NSApp.windows.filter { window in
                    let isOpener = window.identifier?.rawValue.hasPrefix(SettingsOpenerView.windowID) ?? false
                    return window.isVisible && window.alphaValue > 0 && window.styleMask.contains(.titled)
                        && window !== settings && !isOpener
                }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
    }
}

enum SettingsWindowFinder {
    /// SwiftUI's Settings window, found by identifier or title.
    @MainActor
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == "com.apple.SwiftUI.Settings" { return true }
            return window.isVisible && window.styleMask.contains(.titled)
                && (window.title.localizedCaseInsensitiveContains("settings")
                    || window.title.localizedCaseInsensitiveContains("preferences"))
        }
    }
}
