import Foundation
import Testing
@testable import DevshoutCore

/// Transcription while recording: chunks the planner cuts during the recording go to the engine straight away, and
/// `stop()` only has the tail left. The scripted planner hands chunk *n* over once `liveAfter[n]` samples have
/// arrived; the default recorder delivers one second (16,000 samples) when it starts.
@Suite struct LiveTranscriptionTests {
    /// Half a second of audio per buffer.
    static func halfSeconds(_ count: Int) -> [[Float]] {
        Array(repeating: [Float](repeating: 0.1, count: 8_000), count: count)
    }

    @Test func chunksAreTranscribedBeforeStop() async throws {
        // Two pauses in the first second: chunks 0 and 1 are cut while recording, and chunk 2 is the tail.
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)

        // Still recording, and two chunks are done already.
        #expect(h.engine.calledIndices == [0, 1])
        #expect(!h.recorder.stopped.get())
        if case .recording = await h.session.state {} else { Issue.record("expected to be recording still") }
        #expect(await h.session.latestProgress == TranscriptionProgress(text: "part 0 part 1", chunksPlanned: 2,
                                                                        chunksDone: 2, planningComplete: false,
                                                                        pendingAudio: 0))

        // After stop only the tail goes to the engine.
        let result = try #require(await h.session.stop())
        let states = await SessionHarness.collect(h.session.states)
        #expect(h.engine.calledIndices == [0, 1, 2])
        #expect(h.engine.calls.get().map(\.context.previousText) == [nil, "part 0", "part 1"])
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(h.stitchedIndices.get().last == [0, 1, 2])
        #expect(result.recording.status == .completed)
        #expect(try h.history.load(id)?.rawText == "part 0 part 1 part 2")
        // The state counts from what was already done.
        let transcribing = states.filter { if case .transcribing = $0 { true } else { false } }
        #expect(transcribing == [.transcribing(done: 0, total: 0), .transcribing(done: 2, total: 3),
                                 .transcribing(done: 3, total: 3)])
    }

    @Test func aChunkStillWithTheEngineAtStopIsWaitedForNotRedone() async throws {
        let gate = Gate()
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)),
                                   engine: FakeEngine(script: [1: [.hold(gate)]]), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let session = h.session
        try await session.start(mode: .raw, targetApp: nil)
        await h.waitForEngineCalls(2)  // chunk 0 is done and chunk 1 is with the engine
        let stopping = Task { await session.stop() }
        for _ in 0..<20_000 {
            if case .transcribing = await session.state { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(h.engine.calledIndices == [0, 1])
        gate.open()
        let result = try #require(await stopping.value)
        #expect(h.engine.calledIndices == [0, 1, 2])
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(result.missingPartsNotice == nil)
    }

    @Test func progressIsPublishedAsChunksFinish() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let session = h.session
        let collecting = Task {
            var all: [TranscriptionProgress] = []
            for await progress in session.progress { all.append(progress) }
            return all
        }
        try await session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)
        _ = await session.stop()
        let all = await collecting.value  // the stream ends with the dictation

        let last = try #require(all.last)
        #expect(last.chunksPlanned == 3)
        #expect(last.chunksDone == 3)
        #expect(last.planningComplete)
        #expect(last.pendingAudio == 0)
        // The preview is the text transcribed while recording.
        #expect(last.text == "part 0 part 1")
        #expect(all.allSatisfy { $0.chunksDone <= $0.chunksPlanned })
        #expect(await session.latestProgress == last)
    }

    @Test func pendingAudioCountsTheChunksNotDone() async throws {
        let gate = Gate()
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)),
                                   engine: FakeEngine(script: [0: [.hold(gate)]]), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForEngineCalls(1)
        for _ in 0..<20_000 {
            if await h.session.latestProgress.chunksPlanned == 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Two chunks of 100 samples each are cut, and neither is finished.
        let progress = await h.session.latestProgress
        #expect(progress.chunksDone == 0)
        #expect(progress.pendingAudio == 200.0 / 16_000)
        #expect(progress.text.isEmpty)
        gate.open()
        _ = await h.session.stop()
        #expect(await h.session.latestProgress.pendingAudio == 0)
    }

    @Test func latestTextIsTheLastWordsThatFit() {
        let progress = TranscriptionProgress(text: "so the idea is  that the\nflag should only show when")
        #expect(progress.latestText(characters: 200) == "so the idea is that the flag should only show when")
        #expect(progress.latestText(characters: 22) == "should only show when")
        #expect(progress.latestText(characters: 0).isEmpty)
        #expect(TranscriptionProgress().latestText(characters: 60).isEmpty)
    }

    // MARK: The same text as transcribing after stop

    /// Speech with pauses, and a stretch too long for one chunk (a forced cut with an overlap).
    static let speech = SpikeAudio.make([(4, true), (1, false), (5, true), (1.2, false), (20, true), (0.7, false),
                                         (2.1, true), (0.3, false)])

    /// Runs `speech` through a session with the real planner and stitcher, in 100 ms buffers. All but the last
    /// second arrives while recording.
    private func dictate(afterStop: Bool) async throws -> (text: String?, chunksBeforeStop: Int, contexts: [String?]) {
        let samples = Self.speech
        var buffers: [[Float]] = []
        var position = 0
        while position < samples.count {
            let end = min(position + 1_600, samples.count)
            buffers.append(Array(samples[position..<end]))
            position = end
        }
        let vad = SpikeFakeVAD()
        let engine = SpikeFakeEngine()
        let planner = VADChunkPlanner(maxChunkDuration: engine.maxChunkDuration, frameSize: vad.frameSize,
                                      defersUntilFinish: afterStop) {
            VADChunkPlanner.Detector(vad: vad, remainder: { vad.remainder() })
        }
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Array(buffers.dropLast(10)),
                                                          tailBuffers: Array(buffers.suffix(10))),
                                   engine: engine, planner: planner, stitch: { Stitcher.stitch($0) })
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForAudio(Double(samples.count - 16_000) / 16_000)
        // Live, the pauses and the forced cut give three chunks before stop. After stop, none can come.
        if !afterStop { await h.waitForChunks(done: 3) }
        let before = await h.session.latestProgress.chunksDone
        let result = try #require(await h.session.stop())
        return (result.recording.rawText, before, engine.contexts.map(\.previousText))
    }

    @Test func liveTranscriptionGivesTheSameTextAsTranscribingAfterStop() async throws {
        let live = try await dictate(afterStop: false)
        let after = try await dictate(afterStop: true)
        #expect(live.chunksBeforeStop == 3)
        #expect(after.chunksBeforeStop == 0)
        #expect(live.text == after.text)
        #expect(live.contexts == after.contexts)

        // And both are what planning the whole recording in one go gives.
        let vad = SpikeFakeVAD()
        var probabilities = try await vad.process(Self.speech)
        if let last = vad.remainder() { probabilities.append(last) }
        let chunks = ChunkPlanner.plan(samples: Self.speech, probabilities: probabilities, frameSize: vad.frameSize,
                                       maxChunkDuration: 14.5)
        #expect(chunks.count == 4)
        #expect(chunks.contains { $0.overlapBefore > 0 })
        let engine = SpikeFakeEngine()
        var transcripts: [ChunkTranscript] = []
        for chunk in chunks { transcripts.append(try await engine.transcribe(chunk, context: TranscriptionContext())) }
        #expect(live.text == Stitcher.stitch(transcripts))
        #expect(live.text?.isEmpty == false)
    }

    // MARK: Cancel

    @Test func cancelStopsBackgroundTranscriptionAtOnce() async throws {
        // Chunk 0 is with the engine and chunk 1 is queued behind it when Esc is pressed.
        let gate = Gate()
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)),
                                   engine: FakeEngine(script: [0: [.hold(gate)]]), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        await h.waitForEngineCalls(1)
        for _ in 0..<20_000 {
            if await h.session.latestProgress.chunksPlanned == 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // cancel() returns while the engine is still holding chunk 0: it doesn't wait for it.
        let result = try #require(await h.session.cancel())
        #expect(result.state == .cancelled)
        #expect(h.recorder.cancelled.get())

        // The engine lets go. Nothing else is transcribed, and the tail is never asked for.
        gate.open()
        await h.session.backgroundWorkEnded()
        #expect(h.engine.calledIndices == [0])
        #expect(h.plannedSampleCounts.isEmpty)
        #expect(h.stitchedIndices.get().isEmpty)
        #expect(h.cleaner.calls.get().isEmpty)
        #expect(h.deliverer.delivered.get().isEmpty)
        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .cancelled)
        #expect(saved.rawText == nil)
        #expect(saved.duration == 1)
        #expect(h.history.audioURL(for: id) != nil)
        #expect(await SessionHarness.collect(h.session.states).last == .cancelled)
        #expect(await h.session.stop() == nil)
    }

    @Test func cancelAfterChunksWereTranscribedDeliversNothing() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)
        let result = try #require(await h.session.cancel())
        await h.session.backgroundWorkEnded()
        #expect(result.state == .cancelled)
        #expect(h.engine.calledIndices == [0, 1])
        #expect(h.deliverer.delivered.get().isEmpty)
        #expect(try h.history.load(id)?.status == .cancelled)
        #expect(try h.history.load(id)?.deliveredText == nil)
    }

    // MARK: Failures while recording

    @Test func aChunkThatFailsWhileRecordingIsRetriedThenLeftOut() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)),
                                   engine: FakeEngine(failAtIndex: 0), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)
        #expect(h.engine.calledIndices == [0, 0, 1])
        #expect(await h.session.latestProgress.text == "part 1")

        let result = try #require(await h.session.stop())
        #expect(h.engine.calledIndices == [0, 0, 1, 2])
        #expect(h.deliverer.delivered.get() == ["Part 1 Part 2"])
        #expect(result.missingPartsNotice == "Part 1 of 3 is missing: see History")
        #expect(try h.history.load(id)?.errorMessage == "Part 1 of 3 (0:00 to 0:14) couldn't be transcribed and is "
            + "missing from the text: engine exploded. The audio was kept.")
    }

    let quickLimits = DictationOptions(minimumChunkTimeout: 0.05, chunkTimeoutPerAudioSecond: 0,
                                       minimumPlanningTimeout: 0.05, planningTimeoutPerAudioSecond: 0)

    @Test func aChunkThatHangsOnceWhileRecordingIsRetried() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)),
                                   engine: FakeEngine(script: [0: [.hang]]), options: quickLimits,
                                   liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)
        #expect(h.engine.calledIndices == [0, 0, 1])
        let result = try #require(await h.session.stop())
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(result.missingPartsNotice == nil)
    }

    @Test func anEngineThatGetsStuckWhileRecordingEndsWithWhatItHas() async throws {
        // Chunk 2 of 4 never answers, twice, during the recording. The chunks after it are not tried, including
        // the tail at stop, and stop doesn't wait for anything.
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(3)),
                                   engine: FakeEngine(script: [1: [.hang, .hang]]), options: quickLimits,
                                   chunkOrder: [0, 1, 2, 3], liveAfter: [8_000, 16_000, 24_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 3)
        #expect(h.engine.calledIndices == [0, 1, 1])
        #expect(await h.session.latestProgress.text == "part 0")

        let result = try #require(await h.session.stop())
        #expect(h.engine.calledIndices == [0, 1, 1])
        #expect(h.deliverer.delivered.get() == ["Part 0"])
        #expect(result.missingPartsNotice == "3 of 4 parts are missing: see History")
        #expect(try h.history.load(id)?.errorMessage == "3 of 4 parts couldn't be transcribed and are missing from "
            + "the text: part 2 (0:14 to 0:29): the engine didn't answer within 0.1 s; "
            + "part 3 (0:29 to 0:43): not tried, because the engine had stopped answering; "
            + "part 4 (0:43 to 0:58): not tried, because the engine had stopped answering. The audio was kept.")
    }

    @Test func aPlannerThatFailsWhileRecordingFailsTheDictationAndKeepsTheText() async throws {
        // Chunk 0 is cut and transcribed, then the planner fails on the next audio.
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), liveAfter: [8_000],
                                   planFailsAfterSamples: 16_000)
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        await h.waitForChunks(done: 1)
        let result = try #require(await h.session.stop())
        #expect(result.state == .failed(stage: .transcribing, message: "Couldn't split the audio: VAD failed"))
        #expect(h.engine.calledIndices == [0])
        #expect(h.deliverer.delivered.get().isEmpty)
        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .failed)
        #expect(saved.rawText == "part 0")
        #expect(h.history.audioURL(for: id) != nil)
    }

    // MARK: The recording is never held up

    /// Seconds of audio the session says it has recorded; nil when it isn't recording.
    static func elapsed(_ session: DictationSession) async -> TimeInterval? {
        if case .recording(let elapsed, _) = await session.state { return elapsed }
        return nil
    }

    @Test func audioKeepsArrivingWhileThePlannerAndTheEngineAreBusy() async throws {
        // A planner that never answers: the recorder's stream is still drained.
        let stuckPlanner = try SessionHarness(planHangs: true)
        defer { stuckPlanner.temp.remove() }
        try await stuckPlanner.session.start(mode: .raw, targetApp: nil)
        stuckPlanner.recorder.send([Float](repeating: 0.2, count: 16_000))
        await stuckPlanner.waitForAudio(2)
        #expect(await Self.elapsed(stuckPlanner.session) == 2)
        let cancelled = try #require(await stuckPlanner.session.cancel())
        #expect(cancelled.recording.duration == 2)

        // An engine holding a chunk: the same.
        let gate = Gate()
        let busyEngine = try SessionHarness(engine: FakeEngine(script: [0: [.hold(gate)]]), liveAfter: [16_000])
        defer { busyEngine.temp.remove() }
        try await busyEngine.session.start(mode: .raw, targetApp: nil)
        await busyEngine.waitForEngineCalls(1)
        busyEngine.recorder.send([Float](repeating: 0.2, count: 16_000))
        await busyEngine.waitForAudio(2)
        #expect(await Self.elapsed(busyEngine.session) == 2)
        gate.open()
        let result = try #require(await busyEngine.session.stop())
        #expect(busyEngine.plannedSampleCounts == [32_000])
        #expect(busyEngine.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(result.recording.status == .completed)
    }

    // MARK: Mode switch and paste raw

    @Test func modeSwitchAfterChunksWereTranscribed() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        await h.waitForChunks(done: 2)
        #expect(await h.session.setMode(.structure))
        _ = await h.session.stop()
        #expect(h.cleaner.calls.get().map(\.mode.id) == [.structure])
        #expect(h.cleaner.calls.get().map(\.raw) == ["Part 0 Part 1 Part 2"])
        #expect(h.deliverer.delivered.get() == ["Cleaned: Part 0 Part 1 Part 2"])
        #expect(try h.history.load(id)?.mode == .structure)
    }

    @Test func pasteRawNowAfterLiveTranscription() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(buffers: Self.halfSeconds(2)), cleaner: .hanging(),
                                   liveAfter: [8_000, 16_000])
        defer { h.temp.remove() }
        let session = h.session
        let watcher = Task {
            for await state in session.states {
                if case .cleaning = state { await session.pasteRawNow() }
            }
        }
        try await session.start(mode: .tidy, targetApp: nil)
        await h.waitForChunks(done: 2)
        let result = try #require(await session.stop())
        await watcher.value
        #expect(result.state == .finished(outcome: .pasted(appName: "Slack"), usedRaw: true,
                                          reason: "You chose to paste the raw text", authFailed: false))
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(h.engine.calledIndices == [0, 1, 2])
    }
}
