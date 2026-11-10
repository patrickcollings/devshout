import Foundation

/// How a dictation hotkey behaves. Raw values match the names the settings use
/// (`tapToggleHoldToTalk`, `toggleOnly`, `holdOnly`), so a settings enum maps across with `init(rawValue:)`.
public enum TapHoldBehaviour: String, Codable, Sendable, CaseIterable, Hashable {
    /// A tap (shorter than the threshold) starts a recording that the next press stops;
    /// holding the key longer is push-to-talk, and letting go stops it.
    case tapToggleHoldToTalk
    /// Every press toggles: the first starts, the next stops. Key-ups are ignored.
    case toggleOnly
    /// Push-to-talk only: key-down starts, key-up stops.
    case holdOnly
}

/// What a hotkey event asks the dictation pipeline to do.
public enum TapHoldAction<Trigger: Hashable & Sendable>: Sendable, Hashable {
    /// Start recording, in the mode this trigger stands for.
    case start(Trigger)
    /// Stop recording and process what was said.
    case stop
    /// Another mode's hotkey was pressed during a recording: carry on recording, but in this trigger's mode.
    case switchMode(Trigger)
    /// Esc during a recording: stop and discard (the audio is kept in history as cancelled).
    case cancel
}

/// Turns raw key-down and key-up events of the dictation hotkeys into start, stop, switch and cancel actions.
///
/// Pure and clock-free: callers pass event times (seconds, any monotonic origin such as `systemUptime`).
/// Rules:
/// - Idle, key-down → `start`. Recording begins on key-down, so nothing said is lost while deciding tap vs hold.
/// - `tapToggleHoldToTalk`: key-up of the starting key after `holdThreshold` or longer → `stop` (push-to-talk);
///   sooner → the recording is latched (toggle) and the next press stops it.
/// - `toggleOnly`: latched from the start; key-ups do nothing.
/// - `holdOnly`: key-up of the starting key → `stop`.
/// - During a recording, key-down of the trigger currently in use → `stop`; of a different trigger → `switchMode`.
///   A switch never changes which key push-to-talk is waiting for.
/// - A key-down for a key that is already down (auto-repeat) is ignored, and so is a key-up for a key not down.
///   (See `keyDown(_:at:repeatsPossible:)` for sources that never repeat.)
public struct TapHoldClassifier<Trigger: Hashable & Sendable>: Sendable {
    public static var defaultHoldThreshold: TimeInterval { 0.35 }

    public enum State: Sendable, Hashable {
        case idle
        /// `starter` began the recording at `startedAt`; `active` is the trigger whose mode is in use now.
        /// `latched` is true once the recording is in toggle mode (it no longer stops on key-up).
        case recording(starter: Trigger, active: Trigger, startedAt: TimeInterval, latched: Bool)
    }

    public var behaviour: TapHoldBehaviour
    public var holdThreshold: TimeInterval
    public private(set) var state: State = .idle
    /// Keys currently held down, with the time each went down.
    public private(set) var held: [Trigger: TimeInterval] = [:]

    public init(behaviour: TapHoldBehaviour = .tapToggleHoldToTalk,
                holdThreshold: TimeInterval = TapHoldClassifier.defaultHoldThreshold) {
        self.behaviour = behaviour
        self.holdThreshold = holdThreshold
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// The trigger whose mode the current recording uses, if recording.
    public var activeTrigger: Trigger? {
        if case let .recording(_, active, _, _) = state { return active }
        return nil
    }

    public func isHeld(_ trigger: Trigger) -> Bool { held[trigger] != nil }

    /// A key went down.
    /// - Parameter repeatsPossible: true (the default) when the event source may send auto-repeat key-downs: a
    ///   key-down for a key already down is then ignored. Pass false when the source never repeats (Carbon hot
    ///   keys through KeyboardShortcuts): a second key-down then means the key-up was missed, so it is replayed
    ///   first. If the replayed key-up stops a push-to-talk recording, this press only stops it.
    public mutating func keyDown(_ trigger: Trigger, at time: TimeInterval,
                                 repeatsPossible: Bool = true) -> TapHoldAction<Trigger>? {
        if held[trigger] != nil {
            if repeatsPossible { return nil } // auto-repeat
            if let replayed = keyUp(trigger, at: time) { return replayed }
        }
        held[trigger] = time

        switch state {
        case .idle:
            state = .recording(starter: trigger, active: trigger, startedAt: time, latched: behaviour == .toggleOnly)
            return .start(trigger)
        case let .recording(starter, active, startedAt, latched):
            if trigger == active {
                state = .idle
                return .stop
            }
            state = .recording(starter: starter, active: trigger, startedAt: startedAt, latched: latched)
            return .switchMode(trigger)
        }
    }

    public mutating func keyUp(_ trigger: Trigger, at time: TimeInterval) -> TapHoldAction<Trigger>? {
        guard held.removeValue(forKey: trigger) != nil else { return nil }

        guard case let .recording(starter, active, startedAt, latched) = state,
              trigger == starter, !latched else { return nil }

        switch behaviour {
        case .holdOnly:
            state = .idle
            return .stop
        case .toggleOnly:
            return nil
        case .tapToggleHoldToTalk:
            if time - startedAt >= holdThreshold {
                state = .idle
                return .stop
            }
            state = .recording(starter: starter, active: active, startedAt: startedAt, latched: true)
            return nil
        }
    }

    /// Esc pressed. Returns `.cancel` only while recording.
    public mutating func cancel() -> TapHoldAction<Trigger>? {
        guard isRecording else { return nil }
        state = .idle
        return .cancel
    }

    /// The recording ended some other way (the overlay's Stop or Cancel button, an error). Keys still held stay
    /// tracked, so their key-ups and repeats are ignored rather than starting anything.
    public mutating func recordingEnded() {
        state = .idle
    }

    /// Forget everything, held keys included (for example after the hotkeys were re-registered).
    public mutating func reset() {
        state = .idle
        held = [:]
    }
}
