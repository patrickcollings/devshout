import Foundation

/// Runs async operations one at a time, in the order they were submitted.
///
/// An actor alone is not enough for the engines: actor methods interleave at every `await`, and Core ML models are
/// not re-entrant. Each operation here starts only after the previous one has finished (or failed).
public actor AsyncSerialQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    /// Runs `operation` after everything submitted before it. Cancelling the caller cancels the operation.
    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs `operation` after everything submitted before it, even if the caller is cancelled. For teardown
    /// (`unload()`), which must happen whatever state the calling task is in.
    public func runUncancellable<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        // An unstructured task does not inherit the caller's cancellation.
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
