import Foundation
import Testing
@testable import DevshoutCore

private enum Key: String, Hashable, Sendable { case dictate, structure, raw, tidy }
private typealias Classifier = TapHoldClassifier<Key>

@Suite struct TapHoldClassifierTests {
    // MARK: tap toggles, hold talks

    @Test func tapStartsAndTapStops() {
        var c = Classifier()
        #expect(c.keyDown(.dictate, at: 0) == .start(.dictate))
        #expect(c.keyUp(.dictate, at: 0.1) == nil)
        #expect(c.isRecording)
        #expect(c.state == .recording(starter: .dictate, active: .dictate, startedAt: 0, latched: true))
        #expect(c.keyDown(.dictate, at: 5) == .stop)
        #expect(!c.isRecording)
        #expect(c.keyUp(.dictate, at: 5.1) == nil)
        #expect(c.held.isEmpty)
    }

    @Test func holdIsPushToTalk() {
        var c = Classifier()
        #expect(c.keyDown(.dictate, at: 10) == .start(.dictate))
        #expect(c.keyUp(.dictate, at: 14) == .stop)
        #expect(c.state == .idle)
    }

    @Test func thresholdBoundary() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        #expect(c.keyUp(.dictate, at: 0.349) == nil) // tap: latched
        _ = c.keyDown(.dictate, at: 1) // stops
        _ = c.keyUp(.dictate, at: 1.1)

        _ = c.keyDown(.dictate, at: 2)
        #expect(c.keyUp(.dictate, at: 2.35) == .stop) // exactly the threshold counts as a hold
    }

    @Test func customThreshold() {
        var c = Classifier(behaviour: .tapToggleHoldToTalk, holdThreshold: 1)
        _ = c.keyDown(.dictate, at: 0)
        #expect(c.keyUp(.dictate, at: 0.5) == nil)
        #expect(c.isRecording)
    }

    @Test func keyRepeatIgnored() {
        var c = Classifier()
        #expect(c.keyDown(.dictate, at: 0) == .start(.dictate))
        #expect(c.keyDown(.dictate, at: 0.5) == nil)
        #expect(c.keyDown(.dictate, at: 0.55) == nil)
        #expect(c.keyUp(.dictate, at: 2) == .stop)
        // A stray key-up for a key that isn't down does nothing.
        #expect(c.keyUp(.dictate, at: 2.1) == nil)
        #expect(c.keyUp(.raw, at: 2.2) == nil)
    }

    // MARK: sources that never repeat (missed key-ups)

    @Test func missedKeyUpDuringHoldStopsWithoutRestarting() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0, repeatsPossible: false)
        // Key-up lost. The next press stops the push-to-talk recording and starts nothing.
        #expect(c.keyDown(.dictate, at: 5, repeatsPossible: false) == .stop)
        #expect(!c.isRecording)
        #expect(!c.isHeld(.dictate))
        #expect(c.keyUp(.dictate, at: 5.1) == nil)
        #expect(c.keyDown(.dictate, at: 6, repeatsPossible: false) == .start(.dictate))
    }

    @Test func missedKeyUpAfterTapStillStops() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0, repeatsPossible: false)
        // Key-up lost 0.1 s in: the replay at 0.2 s still counts as a tap, so the recording latched, and this press stops it.
        #expect(c.keyDown(.dictate, at: 0.2, repeatsPossible: false) == .stop)
    }

    @Test func missedKeyUpWhileIdleStartsAfresh() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0, repeatsPossible: false)
        c.recordingEnded()
        #expect(c.keyDown(.dictate, at: 3, repeatsPossible: false) == .start(.dictate))
    }

    @Test func repeatWhileLatchedDoesNotStop() {
        var c = Classifier(behaviour: .toggleOnly)
        _ = c.keyDown(.dictate, at: 0)
        #expect(c.keyDown(.dictate, at: 0.6) == nil) // still held: repeat
        _ = c.keyUp(.dictate, at: 1)
        #expect(c.isRecording)
    }

    // MARK: switching mode

    @Test func anotherModeKeySwitchesDuringToggle() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        _ = c.keyUp(.dictate, at: 0.1)
        #expect(c.keyDown(.structure, at: 3) == .switchMode(.structure))
        #expect(c.keyUp(.structure, at: 3.1) == nil)
        #expect(c.activeTrigger == .structure)
        #expect(c.isRecording)
        // Pressing the original key now switches back rather than stopping.
        #expect(c.keyDown(.dictate, at: 4) == .switchMode(.dictate))
        _ = c.keyUp(.dictate, at: 4.1)
        #expect(c.keyDown(.dictate, at: 6) == .stop)
    }

    @Test func pressingTheSwitchedToKeyAgainStops() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        _ = c.keyUp(.dictate, at: 0.1)
        _ = c.keyDown(.raw, at: 1)
        _ = c.keyUp(.raw, at: 1.1)
        #expect(c.keyDown(.raw, at: 2) == .stop)
    }

    @Test func switchDuringHoldStillStopsOnStarterRelease() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        #expect(c.keyDown(.structure, at: 1) == .switchMode(.structure))
        #expect(c.keyUp(.structure, at: 1.2) == nil)
        #expect(c.keyUp(.dictate, at: 3) == .stop)
    }

    @Test func switchSoonAfterStartThenTapRelease() {
        // Pressed dictate, switched before the threshold, released dictate quickly: latched in the new mode.
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        _ = c.keyDown(.tidy, at: 0.1)
        _ = c.keyUp(.tidy, at: 0.15)
        #expect(c.keyUp(.dictate, at: 0.2) == nil)
        #expect(c.state == .recording(starter: .dictate, active: .tidy, startedAt: 0, latched: true))
        #expect(c.keyDown(.tidy, at: 2) == .stop)
    }

    // MARK: behaviours

    @Test func toggleOnlyIgnoresHold() {
        var c = Classifier(behaviour: .toggleOnly)
        #expect(c.keyDown(.dictate, at: 0) == .start(.dictate))
        #expect(c.keyUp(.dictate, at: 10) == nil)
        #expect(c.isRecording)
        #expect(c.keyDown(.dictate, at: 20) == .stop)
    }

    @Test func holdOnlyStopsOnAnyRelease() {
        var c = Classifier(behaviour: .holdOnly)
        #expect(c.keyDown(.dictate, at: 0) == .start(.dictate))
        #expect(c.keyUp(.dictate, at: 0.05) == .stop)
        #expect(c.keyDown(.raw, at: 1) == .start(.raw))
        #expect(c.keyDown(.structure, at: 1.5) == .switchMode(.structure))
        #expect(c.keyUp(.structure, at: 1.6) == nil)
        #expect(c.keyUp(.raw, at: 4) == .stop)
    }

    @Test func behaviourRawValuesMatchSettingsNames() {
        #expect(TapHoldBehaviour(rawValue: "tapToggleHoldToTalk") == .tapToggleHoldToTalk)
        #expect(TapHoldBehaviour(rawValue: "toggleOnly") == .toggleOnly)
        #expect(TapHoldBehaviour(rawValue: "holdOnly") == .holdOnly)
    }

    // MARK: cancel and outside stops

    @Test func cancelOnlyWhileRecording() {
        var c = Classifier()
        #expect(c.cancel() == nil)
        _ = c.keyDown(.dictate, at: 0)
        #expect(c.cancel() == .cancel)
        #expect(!c.isRecording)
        // The key is still held; its release does nothing.
        #expect(c.keyUp(.dictate, at: 2) == nil)
        #expect(c.cancel() == nil)
    }

    @Test func recordingEndedElsewhereKeepsHeldKeys() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        c.recordingEnded() // e.g. the overlay's Stop button
        #expect(c.keyDown(.dictate, at: 0.5) == nil) // repeat of a held key
        #expect(c.keyUp(.dictate, at: 1) == nil)
        #expect(c.keyDown(.dictate, at: 2) == .start(.dictate))
    }

    @Test func resetForgetsHeldKeys() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        c.reset()
        #expect(!c.isHeld(.dictate))
        #expect(c.keyDown(.dictate, at: 1) == .start(.dictate))
    }

    @Test func changingBehaviourMidRecordingKeepsState() {
        var c = Classifier()
        _ = c.keyDown(.dictate, at: 0)
        c.behaviour = .toggleOnly
        // Not latched yet, but toggleOnly ignores key-ups.
        #expect(c.keyUp(.dictate, at: 5) == nil)
        #expect(c.keyDown(.dictate, at: 6) == .stop)
    }
}
