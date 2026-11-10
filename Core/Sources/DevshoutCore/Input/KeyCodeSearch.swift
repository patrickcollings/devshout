import Foundation

/// Finds the virtual key code that types a character in the current keyboard layout. The macOS side supplies
/// `translate` (UCKeyTranslate over the layout data); this part is pure so it can be tested on Linux.
public enum KeyCodeSearch {
    /// kVK_ANSI_V: the "V" key on a US layout.
    public static let ansiV: UInt16 = 9

    /// Returns the first key code in `codes` whose translation equals `character` (case-insensitive), trying
    /// `preferred` first so a layout where several keys type the same letter keeps the usual key.
    /// Returns nil when no key types it (e.g. a non-Latin layout), and the caller falls back to `ansiV`.
    public static func keyCode(producing character: Character,
                               preferred: UInt16? = ansiV,
                               codes: Range<UInt16> = 0..<128,
                               translate: (UInt16) -> String?) -> UInt16? {
        let target = String(character).lowercased()
        func matches(_ code: UInt16) -> Bool {
            guard let s = translate(code), !s.isEmpty else { return false }
            return s.lowercased() == target
        }
        if let preferred, codes.contains(preferred), matches(preferred) { return preferred }
        return codes.first(where: matches)
    }
}

/// Polls a condition until it holds, for permission prompts the system doesn't notify about
/// (Accessibility trust, for one).
public enum Poller {
    /// Returns true once `condition` holds, or false if the task was cancelled or `timeout` passed first.
    /// The condition is checked straight away, then every `interval`.
    public static func waitUntil(interval: Duration = .seconds(1),
                                 timeout: Duration? = nil,
                                 _ condition: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        while !Task.isCancelled {
            if await condition() { return true }
            if let deadline, clock.now >= deadline { return false }
            do { try await Task.sleep(for: interval) } catch { return false }
        }
        return false
    }
}
