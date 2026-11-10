// Start and stop ticks (PLAN §7.3): built-in macOS sounds, quiet, and off when the setting says so.
//
// Unverified on macOS (written on Linux):
// - The names resolve to /System/Library/Sounds/{Tink,Pop,Bottle}.aiff through NSSound(named:).
// - Volume 0.35 is a guess at "soft"; adjust after hearing it.

import AppKit
import Foundation

@MainActor
public final class Sounds {
    public enum Cue: Sendable, CaseIterable {
        case start, stop, cancel

        var soundName: String {
            switch self {
            case .start: "Tink"
            case .stop: "Pop"
            case .cancel: "Bottle"
            }
        }
    }

    /// Read before every cue, so the setting applies straight away.
    public var isEnabled: () -> Bool
    public var volume: Float

    private var cache: [Cue: NSSound] = [:]

    public init(volume: Float = 0.35, isEnabled: @escaping () -> Bool = { true }) {
        self.volume = volume
        self.isEnabled = isEnabled
    }

    public func play(_ cue: Cue) {
        guard isEnabled(), let sound = sound(for: cue) else { return }
        if sound.isPlaying { sound.stop() }
        sound.volume = volume
        sound.play()
    }

    private func sound(for cue: Cue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        guard let sound = NSSound(named: NSSound.Name(cue.soundName)) else { return nil }
        cache[cue] = sound
        return sound
    }
}
