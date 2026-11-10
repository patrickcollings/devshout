import Foundation
import Testing
@testable import DevshoutCore

private actor Recorder {
    var events: [String] = []
    var running = 0
    var maxRunning = 0

    func begin(_ name: String) {
        running += 1
        maxRunning = max(maxRunning, running)
        events.append("start \(name)")
    }

    func end(_ name: String) {
        running -= 1
        events.append("end \(name)")
    }
}

private struct Boom: Error {}

@Suite struct AsyncSerialQueueTests {
    @Test func runsOneAtATime() async throws {
        let queue = AsyncSerialQueue()
        let recorder = Recorder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    _ = try await queue.run {
                        await recorder.begin("\(i)")
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await recorder.end("\(i)")
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await recorder.maxRunning == 1)
        let events = await recorder.events
        #expect(events.count == 10)
        // Never interleaved: every start is followed by the end of the same operation.
        for pair in stride(from: 0, to: events.count, by: 2) {
            let name = events[pair].dropFirst("start ".count)
            #expect(events[pair + 1] == "end \(name)")
        }
    }

    @Test func keepsSubmissionOrder() async throws {
        let queue = AsyncSerialQueue()
        let recorder = Recorder()
        // Each run is submitted from the same task only after the previous one has been queued, by awaiting a
        // submission that has already reached the queue (the first call blocks the queue until released).
        let gate = AsyncStream<Void>.makeStream()
        let first = Task {
            try await queue.run {
                for await _ in gate.stream {}
                await recorder.begin("0")
                await recorder.end("0")
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        var later: [Task<Void, Error>] = []
        for i in 1...3 {
            later.append(Task {
                try await queue.run {
                    await recorder.begin("\(i)")
                    await recorder.end("\(i)")
                }
            })
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        gate.continuation.finish()
        try await first.value
        for task in later { try await task.value }
        #expect(await recorder.events == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2", "start 3", "end 3"])
    }

    @Test func failureDoesNotBlockTheNext() async throws {
        let queue = AsyncSerialQueue()
        await #expect(throws: Boom.self) {
            try await queue.run { () async throws -> Int in throw Boom() }
        }
        let value = try await queue.run { 42 }
        #expect(value == 42)
    }

    @Test func runIsSkippedWhenTheCallerIsCancelled() async throws {
        let queue = AsyncSerialQueue()
        let recorder = Recorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run { await recorder.begin("op") }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await recorder.events.isEmpty)
    }

    @Test func uncancellableRunsEvenWhenTheCallerIsCancelled() async throws {
        let queue = AsyncSerialQueue()
        let recorder = Recorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await queue.runUncancellable { await recorder.begin("unload") }
        }
        await task.value
        #expect(await recorder.events == ["start unload"])
    }

    @Test func uncancellableWaitsForEarlierWork() async throws {
        let queue = AsyncSerialQueue()
        let recorder = Recorder()
        async let first: Void = queue.run {
            await recorder.begin("prepare")
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.end("prepare")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await queue.runUncancellable { await recorder.begin("unload") }
        try await first
        #expect(await recorder.events == ["start prepare", "end prepare", "start unload"])
    }

    @Test func returnsValues() async throws {
        let queue = AsyncSerialQueue()
        async let a = queue.run { "a" }
        async let b = queue.run { "b" }
        let results = try await [a, b]
        #expect(Set(results) == ["a", "b"])
    }
}
