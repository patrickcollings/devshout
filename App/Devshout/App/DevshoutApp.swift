import AppKit
import DevshoutCore
import DevshoutMac
import SwiftUI

/// devshout: a menu bar app (LSUIElement, no Dock icon). The only SwiftUI scene is the menu bar menu and icon.
/// The onboarding and Settings windows are AppKit windows (`OnboardingWindowController`,
/// `SettingsWindowController`), so they can open at launch and from the menu without a SwiftUI view to call
/// `openWindow` or `openSettings`. Everything else is owned by `AppCoordinator`.
@main
struct DevshoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var models: DevshoutViewModels { AppCoordinator.shared.models }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: models.menuBar)
        } label: {
            MenuBarLabel(model: models.menuBar)
        }

    }
}
