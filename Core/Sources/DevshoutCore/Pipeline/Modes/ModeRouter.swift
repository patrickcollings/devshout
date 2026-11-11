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
    /// `settings.defaultMode`. A custom mode that is no longer in the settings is never returned: a per-app rule
    /// for one is skipped, and anything else falls back to the default mode, or to Tidy if that is gone too.
    public static func resolve(trigger: HotkeyTrigger, frontmostBundleID: String?, settings: AppSettings) -> ModeID {
        let fallback = settings.hasMode(settings.defaultMode) ? settings.defaultMode : AppSettings.fallbackMode
        switch trigger {
        case .mode(let mode):
            return settings.hasMode(mode) ? mode : fallback
        case .defaultForApp:
            if let bundleID = frontmostBundleID, let mode = settings.perAppModes[bundleID], settings.hasMode(mode) {
                return mode
            }
            if let bundleID = frontmostBundleID,
               let match = settings.perAppModes.first(where: {
                   $0.key.caseInsensitiveCompare(bundleID) == .orderedSame && settings.hasMode($0.value)
               }) {
                // Bundle IDs are case-insensitive on macOS; exact matches win above.
                return match.value
            }
            return fallback
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
