import Testing
@testable import DevshoutCore

@Suite struct ModelProgressSmootherTests {
    @Test func fractionNeverGoesBackWithinAPhase() {
        var smoother = ModelProgressSmoother()
        #expect(smoother.smooth(ModelProgress(phase: .downloading, fraction: 0.4))?.fraction == 0.4)
        #expect(smoother.smooth(ModelProgress(phase: .downloading, fraction: 0.1)) == nil)  // unchanged after lifting
        #expect(smoother.smooth(ModelProgress(phase: .downloading, fraction: 0.6))?.fraction == 0.6)
    }

    @Test func newPhaseStartsAfresh() {
        var smoother = ModelProgressSmoother()
        _ = smoother.smooth(ModelProgress(phase: .downloading, fraction: 0.9))
        #expect(smoother.smooth(ModelProgress(phase: .compiling, fraction: 0.1))?.fraction == 0.1)
    }

    @Test func earlierPhaseIsDropped() {
        var smoother = ModelProgressSmoother()
        _ = smoother.smooth(ModelProgress(phase: .loading))
        #expect(smoother.smooth(ModelProgress(phase: .downloading, fraction: 0.2)) == nil)
        #expect(smoother.smooth(ModelProgress(phase: .ready))?.phase == .ready)
    }

    @Test func clampsAndHandlesNaN() {
        var smoother = ModelProgressSmoother()
        #expect(smoother.smooth(ModelProgress(phase: .downloading, fraction: 1.7))?.fraction == 1)
        var other = ModelProgressSmoother()
        #expect(other.smooth(ModelProgress(phase: .downloading, fraction: .nan))?.fraction == 0)
    }

    @Test func unknownFractionPassesThrough() {
        var smoother = ModelProgressSmoother()
        _ = smoother.smooth(ModelProgress(phase: .compiling, fraction: 0.5))
        #expect(smoother.smooth(ModelProgress(phase: .compiling, fraction: nil))?.fraction == nil)
    }

    @Test func duplicatesAreDropped() {
        var smoother = ModelProgressSmoother()
        #expect(smoother.smooth(ModelProgress(phase: .loading)) != nil)
        #expect(smoother.smooth(ModelProgress(phase: .loading)) == nil)
    }

    @Test func relayForwardsSmoothedUpdates() {
        final class Box: @unchecked Sendable { var seen: [ModelProgress] = [] }
        let box = Box()
        let relay = ModelProgressRelay { box.seen.append($0) }
        relay.send(ModelProgress(phase: .downloading, fraction: 0.5))
        relay.send(ModelProgress(phase: .downloading, fraction: 0.2))
        relay.send(ModelProgress(phase: .ready))
        #expect(box.seen.map(\.phase) == [.downloading, .ready])
    }
}
