import Foundation

/// Tidies the progress an engine library reports before it reaches the UI.
///
/// Libraries report each model component separately, so a raw fraction can jump back to 0 when the next component
/// starts. Within one phase the smoother never lets the fraction go backwards (except to nil, which means
/// "unknown") and clamps it to 0...1. A new phase starts afresh, and a phase may not go back to an earlier one
/// (downloading → compiling → loading → ready).
public struct ModelProgressSmoother: Sendable {
    private var last: ModelProgress?

    public init() {}

    /// The progress to show, or nil when this update should be dropped (unchanged, or an earlier phase).
    public mutating func smooth(_ update: ModelProgress) -> ModelProgress? {
        var next = update
        next.fraction = update.fraction.map { min(1, max(0, $0.isFinite ? $0 : 0)) }

        if let last {
            let lastRank = Self.rank(last.phase)
            let nextRank = Self.rank(next.phase)
            if nextRank < lastRank { return nil }
            if nextRank == lastRank {
                if let previous = last.fraction, let fraction = next.fraction, fraction < previous {
                    next.fraction = previous
                }
                if next == last { return nil }
            }
        }
        last = next
        return next
    }

    static func rank(_ phase: ModelProgress.Phase) -> Int {
        switch phase {
        case .downloading: 0
        case .compiling: 1
        case .loading: 2
        case .ready: 3
        }
    }
}

/// A thread-safe wrapper so a `@Sendable` progress callback can smooth updates from any queue.
public final class ModelProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var smoother = ModelProgressSmoother()
    private let handler: @Sendable (ModelProgress) -> Void

    public init(_ handler: @escaping @Sendable (ModelProgress) -> Void) {
        self.handler = handler
    }

    public func send(_ update: ModelProgress) {
        lock.lock()
        let smoothed = smoother.smooth(update)
        lock.unlock()
        if let smoothed { handler(smoothed) }
    }
}
