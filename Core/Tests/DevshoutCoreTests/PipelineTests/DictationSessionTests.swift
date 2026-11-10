import Foundation
import Testing
@testable import DevshoutCore

@Suite struct DictationSessionTests {
    let slack = TargetApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    @Test func happyPathTidy() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: slack)
        await h.waitForAudio(1)
        let result = try #require(await h.session.stop())
        let states = await SessionHarness.collect(h.session.states)

        let fixed = "Part 0 Part 1 Part 2"
        #expect(h.deliverer.delivered.get() == ["Cleaned: \(fixed)"])
        let call = try #require(h.cleaner.calls.get().first)
        #expect(call.raw == fixed)
        #expect(call.mode == ModeConfig.defaults[.tidy])
        #expect(call.glossary == "## Terms\n- CORSIA")

        #expect(result.state == .finished(outcome: .pasted(appName: "Slack"), usedRaw: false, reason: nil, authFailed: false))
        #expect(states.first == .recording(elapsed: 0, level: nil))
        #expect(states.contains { state in
            if case .recording(let elapsed, let level?) = state { elapsed == 1 && abs(level - 0.1) < 0.001 } else { false }
        })
        #expect(states.contains(.transcribing(done: 3, total: 3)))
        #expect(states.contains(.cleaning(model: "haiku")))
        #expect(states.suffix(2) == [.delivering, result.state])

        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .completed)
        #expect(saved.rawText == "part 0 part 1 part 2")
        #expect(saved.fixedText == fixed)
        #expect(saved.fixesApplied)
        #expect(saved.mode == .tidy)
        #expect(saved.engine == .parakeetV3)
        #expect(saved.targetApp == slack)
        #expect(saved.duration == 1)
        #expect(saved.versions.count == 1)
        #expect(saved.versions.first?.model == "haiku")
        #expect(saved.versions.first?.warnings == ["note"])
        #expect(saved.deliveredText == "Cleaned: \(fixed)")
        #expect(saved.delivered?.outcome == .pasted(appName: "Slack"))
        #expect(saved.timings.total != nil)
        #expect(saved.fallbackReason == nil)
        #expect(h.history.audioURL(for: id) != nil)
        #expect(h.recorder.startedURL.get() == h.history.audioURL(for: id))
    }

    @Test func claudeTimeoutPastesRawAndRecordsWhy() async throws {
        let h = try SessionHarness(cleaner: .failing(.timedOut(after: 20)))
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: slack)
        let result = try #require(await h.session.stop())

        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        guard case .finished(_, let usedRaw, let reason, let authFailed) = result.state else {
            Issue.record("expected finished, got \(result.state)")
            return
        }
        #expect(usedRaw)
        #expect(reason == "Claude timed out after 20 s")
        #expect(!authFailed)
        #expect(result.cleanError == .timedOut(after: 20))
        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .completed)
        #expect(saved.versions.isEmpty)
        #expect(saved.fallbackReason == "Claude timed out after 20 s")
        #expect(saved.deliveredText == "Part 0 Part 1 Part 2")
    }

    @Test func hangingCleanerIsAbandonedAfterTimeoutPlusGrace() async throws {
        var settings = AppSettings()
        settings.modes[.tidy]?.timeout = 0.05
        let h = try SessionHarness(cleaner: .hanging(), settings: settings,
                                   options: DictationOptions(cleanGracePeriod: 0.05))
        defer { h.temp.remove() }
        try await h.session.start(mode: .tidy, targetApp: nil)
        let started = Date()
        let result = try #require(await h.session.stop())
        #expect(Date().timeIntervalSince(started) < 9) // the fake hangs for 10 s; generous for loaded CI machines
        #expect(result.cleanError == .timedOut(after: 0.05))
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func pasteRawNowStopsWaitingForClaude() async throws {
        let h = try SessionHarness(cleaner: .hanging())
        defer { h.temp.remove() }
        let session = h.session
        let watcher = Task {
            for await state in session.states {
                if case .cleaning = state { await session.pasteRawNow() }
            }
        }
        try await session.start(mode: .structure, targetApp: nil)
        let result = try #require(await session.stop())
        await watcher.value
        #expect(result.state == .finished(outcome: .pasted(appName: "Slack"), usedRaw: true,
                                          reason: "You chose to paste the raw text", authFailed: false))
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func authFailureIsFlagged() async throws {
        let h = try SessionHarness(cleaner: .failing(.authFailed(message: "OAuth token has expired")))
        defer { h.temp.remove() }
        try await h.session.start(mode: .tidy, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(result.authFailed)
        #expect(result.state == .finished(outcome: .pasted(appName: "Slack"), usedRaw: true,
                                          reason: "Claude sign-in has expired or was revoked", authFailed: true))
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func nonAuthFailuresAreNotFlagged() async throws {
        for error: CleanError in [.notConnected, .claudeNotFound, .processFailed(exitCode: 1, message: "boom"),
                                  .rejectedOutput(reason: "answered the question")] {
            let h = try SessionHarness(cleaner: .failing(error))
            defer { h.temp.remove() }
            try await h.session.start(mode: .tidy, targetApp: nil)
            let result = try #require(await h.session.stop())
            #expect(!result.authFailed)
            #expect(result.cleanError == error)
            #expect(result.recording.fallbackReason != nil)
        }
    }

    @Test func emptyCleanOutputFallsBackToRaw() async throws {
        let h = try SessionHarness(cleaner: FakeCleaner { _, mode, _ in
            CleanResult(text: "  \n", model: mode.claudeModel, elapsed: 0.1)
        })
        defer { h.temp.remove() }
        try await h.session.start(mode: .tidy, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(result.cleanError == .rejectedOutput(reason: "empty output"))
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func cancelKeepsAudioAndSavesCancelled() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: slack)
        let result = try #require(await h.session.cancel())
        let states = await SessionHarness.collect(h.session.states)

        #expect(result.state == .cancelled)
        #expect(states.last == .cancelled)
        #expect(h.recorder.cancelled.get())
        #expect(!h.recorder.stopped.get())
        #expect(h.engine.calledIndices.isEmpty)
        #expect(h.cleaner.calls.get().isEmpty)
        #expect(h.deliverer.delivered.get().isEmpty)
        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .cancelled)
        #expect(saved.duration == 1)
        #expect(h.history.audioURL(for: id) != nil)
        // A cancelled session can't be stopped afterwards.
        #expect(await h.session.stop() == nil)
    }

    @Test func engineFailureFailsButSavesTextAndAudio() async throws {
        let h = try SessionHarness(engine: FakeEngine(failAtIndex: 1))
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        let result = try #require(await h.session.stop())

        guard case .failed(let stage, let message) = result.state else {
            Issue.record("expected failed, got \(result.state)")
            return
        }
        #expect(stage == .transcribing)
        #expect(message.contains("engine exploded"))
        #expect(h.deliverer.delivered.get().isEmpty)
        #expect(h.cleaner.calls.get().isEmpty)
        let saved = try #require(try h.history.load(id))
        #expect(saved.status == .failed)
        #expect(saved.rawText == "part 0")
        #expect(saved.errorMessage == message)
        #expect(h.history.audioURL(for: id) != nil)
    }

    @Test func chunkPlanningFailureIsSaved() async throws {
        let h = try SessionHarness(planError: FakeError(message: "VAD failed"))
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(result.state == .failed(stage: .transcribing, message: "Couldn't split the audio: VAD failed"))
        #expect(try h.history.load(id)?.status == .failed)
    }

    @Test func noSpeechFailsWithoutDelivering() async throws {
        let h = try SessionHarness(chunkOrder: [])
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(result.state == .failed(stage: .transcribing, message: "No speech was detected."))
        #expect(h.deliverer.delivered.get().isEmpty)
        #expect(try h.history.load(id)?.status == .failed)
        #expect(h.history.audioURL(for: id) != nil)
    }

    @Test func rawModeSkipsTheCleaner() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        let result = try #require(await h.session.stop())
        let states = await SessionHarness.collect(h.session.states)

        #expect(h.cleaner.calls.get().isEmpty)
        #expect(!states.contains { if case .cleaning = $0 { true } else { false } })
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(result.state == .finished(outcome: .pasted(appName: "Slack"), usedRaw: false, reason: nil, authFailed: false))
        let saved = try #require(try h.history.load(id))
        #expect(saved.versions.isEmpty)
        #expect(saved.timings.cleaning == nil)
    }

    @Test func glossaryFixesCanBeSwitchedOff() async throws {
        var settings = AppSettings()
        settings.applyGlossaryFixes = false
        let h = try SessionHarness(settings: settings)
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.deliverer.delivered.get() == ["part 0 part 1 part 2"])
        let saved = try #require(try h.history.load(id))
        #expect(!saved.fixesApplied)
        #expect(saved.fixedText == nil)
    }

    @Test func chunksAreTranscribedAndStitchedInOrder() async throws {
        let h = try SessionHarness(chunkOrder: [2, 0, 1])
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.engine.calledIndices == [0, 1, 2])
        #expect(h.stitchedIndices.get() == [[0, 1, 2]])
        let contexts = h.engine.calls.get().map(\.context)
        #expect(contexts.map(\.previousText) == [nil, "part 0", "part 1"])
        // Parakeet takes no vocabulary prompt.
        #expect(contexts.allSatisfy { $0.vocabularyPrompt == nil })
        #expect(contexts.allSatisfy { $0.language == "en" })
    }

    @Test func vocabularyPromptGoesToEnginesThatTakeIt() async throws {
        let h = try SessionHarness(engine: FakeEngine(id: .whisperLargeV3Turbo, acceptsVocabularyPrompt: true))
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .raw, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.engine.calls.get().allSatisfy { $0.context.vocabularyPrompt == "CORSIA, NDC" })
        #expect(try h.history.load(id)?.engine == .whisperLargeV3Turbo)
    }

    @Test func samplesFlushedAtStopAreKept() async throws {
        let recorder = FakeRecorder(buffers: [[Float](repeating: 0, count: 800)],
                                    tailBuffers: [[Float](repeating: 0, count: 200), [Float](repeating: 0, count: 100)])
        let h = try SessionHarness(recorder: recorder)
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.plannedSampleCounts.get() == [1_100])
    }

    @Test func aRecorderThatNeverFinishesItsStreamDoesNotHang() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(finishesStream: false),
                                   options: DictationOptions(streamDrainTimeout: 0.05))
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(h.plannedSampleCounts.get() == [16_000])
        #expect(result.recording.status == .completed)
    }

    @Test func recorderStopErrorStillTranscribesWhatWasCaptured() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(stopError: FakeError(message: "device vanished")))
        defer { h.temp.remove() }
        try await h.session.start(mode: .raw, targetApp: nil)
        let result = try #require(await h.session.stop())
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        #expect(result.recording.errorMessage == "The recorder reported: device vanished")
        #expect(result.recording.duration == 1)
    }

    @Test func modeSwitchMidRecording() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        #expect(await h.session.setMode(.structure))
        #expect(await h.session.mode == .structure)
        _ = await h.session.stop()
        #expect(h.cleaner.calls.get().map(\.mode.id) == [.structure])
        #expect(h.cleaner.calls.get().first?.mode.claudeModel == "sonnet")
        let saved = try #require(try h.history.load(id))
        #expect(saved.mode == .structure)
        #expect(saved.versions.first?.mode == .structure)
        // Too late once finished.
        #expect(await h.session.setMode(.raw) == false)
    }

    @Test func switchingToRawMidRecordingSkipsClaude() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        try await h.session.start(mode: .structure, targetApp: nil)
        await h.session.setMode(.raw)
        _ = await h.session.stop()
        #expect(h.cleaner.calls.get().isEmpty)
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func customModeConfigIsUsed() async throws {
        var settings = AppSettings()
        settings.modes[.tidy] = ModeConfig(id: .tidy, claudeModel: "sonnet", timeout: 30, customInstructions: "Be brief.")
        let h = try SessionHarness(settings: settings)
        defer { h.temp.remove() }
        try await h.session.start(mode: .tidy, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.cleaner.calls.get().first?.mode == settings.modes[.tidy])
    }

    @Test func recorderStartFailureThrowsAndKeepsNothing() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(startError: FakeError(message: "no microphone")))
        defer { h.temp.remove() }
        await #expect(throws: FakeError.self) {
            try await h.session.start(mode: .tidy, targetApp: nil)
        }
        let states = await SessionHarness.collect(h.session.states)
        #expect(states == [.failed(stage: .recording, message: "Couldn't start recording: no microphone")])
        #expect(h.history.list().isEmpty)
        #expect(h.history.recoverOrphans().isEmpty)
        #expect(await h.session.stop() == nil)
    }

    @Test func aSessionStartsOnlyOnce() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        try await h.session.start(mode: .tidy, targetApp: nil)
        await #expect(throws: DictationSessionError.alreadyStarted) {
            try await h.session.start(mode: .tidy, targetApp: nil)
        }
        _ = await h.session.cancel()
    }

    @Test func stopDuringRecorderStartUpWaitsAndStops() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(startDelay: 0.2))
        defer { h.temp.remove() }
        let session = h.session
        let starting = Task { try await session.start(mode: .raw, targetApp: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)  // the key-up lands while the recorder is starting
        #expect(h.recorder.startedURL.get() == nil)
        let result = try #require(await session.stop())
        let id = try await starting.value
        #expect(h.recorder.stopped.get())
        #expect(result.recording.id == id)
        #expect(result.recording.status == .completed)
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
    }

    @Test func cancelDuringRecorderStartUpWaitsAndCancels() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(startDelay: 0.2))
        defer { h.temp.remove() }
        let session = h.session
        let starting = Task { try await session.start(mode: .tidy, targetApp: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let result = try #require(await session.cancel())
        let id = try await starting.value
        #expect(h.recorder.cancelled.get())
        #expect(result.state == .cancelled)
        #expect(try h.history.load(id)?.status == .cancelled)
        #expect(h.deliverer.delivered.get().isEmpty)
    }

    @Test func stopDuringAFailedStartUpReturnsNil() async throws {
        let h = try SessionHarness(recorder: FakeRecorder(startError: FakeError(message: "no microphone"), startDelay: 0.2))
        defer { h.temp.remove() }
        let session = h.session
        let starting = Task { try await session.start(mode: .tidy, targetApp: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await session.stop() == nil)
        await #expect(throws: FakeError.self) { try await starting.value }
        #expect(await session.state == .failed(stage: .recording, message: "Couldn't start recording: no microphone"))
    }

    @Test func stopAndCancelBeforeStartDoNothing() async throws {
        let h = try SessionHarness()
        defer { h.temp.remove() }
        #expect(await h.session.stop() == nil)
        #expect(await h.session.cancel() == nil)
        #expect(await h.session.state == .idle)
    }

    @Test func tailIsCutAtAWordBoundary() {
        #expect(DictationSession.tail(of: nil, characters: 10) == nil)
        #expect(DictationSession.tail(of: "short", characters: 10) == "short")
        #expect(DictationSession.tail(of: "the quick brown fox jumps", characters: 12) == "fox jumps")
        #expect(DictationSession.rms([]) == nil)
        #expect(DictationSession.rms([0.5, -0.5]) == 0.5)
    }
}
