import AppKit
import DevshoutCore
import DevshoutMac
import SwiftUI

/// devshout: a menu bar app (LSUIElement, no Dock icon). Scenes:
/// - a hidden 1×1 window hosting `SettingsOpenerView`, which opens Settings on request (SwiftUI only lets a live
///   view call `openSettings`; see SettingsOpener.swift). It must come before the Settings scene.
/// - the menu bar menu and icon,
/// - the Settings window.
/// The onboarding window is an AppKit window (`OnboardingWindowController`), so it can open at launch and from the
/// menu without a SwiftUI view to call `openWindow`. Everything else is owned by `AppCoordinator`.
@main
struct DevshoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var models: DevshoutViewModels { AppCoordinator.shared.models }

    var body: some Scene {
        Window("devshout", id: SettingsOpenerView.windowID) {
            SettingsOpenerView()
                .background(HiddenWindowConfigurator())
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            MenuBarContent(model: models.menuBar)
        } label: {
            MenuBarLabel(model: models.menuBar)
        }

        Settings {
            SettingsView(models: models)
        }
    }
}
