// Launch at login through SMAppService.mainApp (macOS 13+), so no helper app or extra package is needed.
//
// Unverified on macOS (written on Linux):
// - For an ad-hoc-signed app, register() may leave the item at .requiresApproval until it is switched on in
//   System Settings → General → Login Items; the UI should offer `openSystemSettings()` then.
// - Running from Xcode's DerivedData registers that copy; register again after moving the app.

import Foundation
import ServiceManagement

public enum LaunchAtLogin {
    public enum Status: Sendable, Hashable {
        case enabled
        case disabled
        /// Registered, but switched off (or not yet approved) in System Settings → Login Items.
        case requiresApproval
        /// macOS can't find the app to register (e.g. running from a disk image).
        case unavailable
    }

    public static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// True when devshout will open at login (registered and approved).
    public static var isEnabled: Bool { status == .enabled }

    /// Registers or unregisters devshout as a login item. Throws SMAppService's error.
    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    /// Opens System Settings → General → Login Items.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
