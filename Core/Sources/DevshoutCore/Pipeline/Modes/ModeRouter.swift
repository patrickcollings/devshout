import Foundation

/// Which hotkey fired (PLAN §7.6).
public enum HotkeyTrigger: Sendable, Hashable {
    /// The generic hotkey (⌥Space): the frontmost app's mode, else the global default.
    case defaultForApp
    /// A mode's own hotkey (⌥⇧Space → Structure, ⌥⌘Space → Raw, …).
    case mode(ModeID)
}

/// What a hotkey press does while a recording is already running.
public enum HotkeyActionWhileRecording: Sendable, Hashable {
    /// Stop and finish the dictation.
    case stop
    /// Keep recording, but finish in this mode.
    case switchMode(ModeID)
}

/// Picks the mode for a dictation. Pure.
public enum ModeRouter {
    /// A mode hotkey gives that mode. The generic hotkey gives the frontmost app's per-app mode, else
    /// `settings.defaultMode`.
    public static func resolve(trigger: HotkeyTrigger, frontmostBundleID: String?, settings: AppSettings) -> ModeID {
        switch trigger {
        case .mode(let mode):
            return mode
        case .defaultForApp:
            if let bundleID = frontmostBundleID, let mode = settings.perAppModes[bundleID] {
                return mode
            }
            if let bundleID = frontmostBundleID,
               let match = settings.perAppModes.first(where: { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                // Bundle IDs are case-insensitive on macOS; exact matches win above.
                return match.value
            }
            return settings.defaultMode
        }
    }

    /// A hotkey pressed during a recording: another mode's hotkey switches the mode (the overlay chip animates);
    /// the generic hotkey, or the hotkey of the mode already in use, stops.
    public static func actionWhileRecording(trigger: HotkeyTrigger, currentMode: ModeID) -> HotkeyActionWhileRecording {
        switch trigger {
        case .defaultForApp:
            return .stop
        case .mode(let mode):
            return mode == currentMode ? .stop : .switchMode(mode)
        }
    }
}
