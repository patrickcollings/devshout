// Hotkey → mode → DictationSession → overlay. One DictationSession per dictation (it is an actor, so recording,
// transcription and clean-up all run off the main actor); this class only starts, stops and cancels it and turns
// its states into the recording pill and the menu bar icon.
//
// v0.1: the whole recording is transcribed after stop (Silero VAD + ChunkPlanner over the full audio). While a
// dictation is still finishing, new triggers are ignored (nothing is queued) and the pill says so.

import AppKit
import DevshoutCore
import DevshoutMac
import Foundation
import KeyboardShortcuts

@MainActor
final class DictationController {
    struct Services {
        var settings: () -> AppSettings
        var engines: EngineController
        var claude: ClaudeController
        var glossary: GlossaryState
        var history: HistoryStore
        var deliverer: any Deliverer
        var recorder: MicRecorder
        var vad: SileroVAD
        var sounds: Sounds
        var levelMeter: LevelMeterController
    }

    /// What the onboarding "Try it" step needs: whether it is showing, and where to put the result.
    struct TryIt {
        var isActive: () -> Bool = { false }
        var deliver: (_ raw: String, _ cleaned: String?, _ delivered: String) -> Void = { _, _, _ in }
    }

    let hotkeys: HotkeyCenter
    var tryIt = TryIt()
    /// A dictation finished (refresh history counts and the like).
    var onFinished: (() -> Void)?
    /// A dictation is about to open the microphone (silence anything devshout itself is playing).
    var onWillStart: (() -> Void)?

    private let services: Services
    private let pill: RecordingPillViewModel
    private let menuBar: MenuBarViewModel
    private var panelStorage: OverlayPanel?
    /// Made on first use (an NSPanel must be created on the main thread, after launch).
    private var panel: OverlayPanel {
        if let panelStorage { return panelStorage }
        let made = OverlayPanel(model: pill)
        panelStorage = made
        return made
    }

    private enum Phase { case idle, starting, recording, finishing }
    private var phase: Phase = .idle
    private var session: DictationSession?
    private var token = UUID()
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Esc, the pill's Cancel or the menu's Cancel Dictation was used for the current dictation.
    private var cancelRequested = false
    /// Closed when a dictation is cancelled after recording stopped, so a late result is never pasted.
    private var deliveryGate = LockedBox(true)
    /// ⌥Return → "Paste raw now" while Claude is tidying (the pill's panel never takes key focus).
    private var returnKeyTask: Task<Void, Never>?

    init(services: Services, pill: RecordingPillViewModel, menuBar: MenuBarViewModel) {
        self.services = services
        self.pill = pill
        self.menuBar = menuBar
        let behaviour = TapHoldBehaviour(rawValue: services.settings().hotkeyBehaviour.rawValue) ?? .tapToggleHoldToTalk
        hotkeys = HotkeyCenter(behaviour: behaviour)
        hotkeys.onAction = { [weak self] action in self?.handle(action) }

        pill.actions = RecordingPillViewModel.Actions(
            stop: { [weak self] in
                self?.hotkeys.recordingEnded()
                self?.stop()
            },
            cancel: { [weak self] in
                self?.hotkeys.recordingEnded()
                self?.cancel()
            },
            pasteRawNow: { [weak self] in self?.pasteRawNow() }
        )
    }

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .starting || phase == .recording }
    var isFinishing: Bool { phase == .finishing }

    func startHotkeys() {
        hotkeys.start()
    }

    func setBehaviour(_ behaviour: HotkeyBehaviour) {
        hotkeys.behaviour = TapHoldBehaviour(rawValue: behaviour.rawValue) ?? .tapToggleHoldToTalk
    }

    // MARK: Menu

    /// The menu's Start/Stop Dictation: goes through the hotkey centre as a tap, so Esc and the next hotkey press
    /// behave exactly as after a real tap.
    func toggleFromMenu() {
        if isRecording {
            hotkeys.recordingEnded()
            stop()
        } else {
            // A latched start whatever the hotkey behaviour (hold-only would stop at the key-up otherwise).
            let behaviour = hotkeys.behaviour
            hotkeys.behaviour = .toggleOnly
            let now = ProcessInfo.processInfo.systemUptime
            hotkeys.handle(.dictate, .down, at: now)
            hotkeys.handle(.dictate, .up, at: now + 0.01)
            hotkeys.behaviour = behaviour
        }
    }

    func cancelFromMenu() {
        hotkeys.recordingEnded()
        cancel()
    }

    // MARK: Hotkeys

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .start(let hotkey):
            if phase == .finishing {
                // The last dictation is still being transcribed or tidied: ignore this press.
                hotkeys.recordingEnded()
                showNotice("Still finishing the last dictation")
                return
            }
            if isRecording {
                // Started from the menu without the hotkey centre knowing: this press stops it.
                hotkeys.recordingEnded()
                stop()
                return
            }
            start(hotkey)
        case .stop:
            stop()
        case .switchMode(let hotkey):
            switchMode(to: hotkey)
        case .cancel:
            cancel()
        }
    }

    private func resolveMode(for hotkey: DictationHotkey) -> ModeID {
        let trigger: HotkeyTrigger = hotkey.mode.map { .mode($0) } ?? .defaultForApp
        let front = FrontmostApp.current
        let bundleID = (front?.isDevshout ?? false) ? nil : front?.bundleID
        return ModeRouter.resolve(trigger: trigger, frontmostBundleID: bundleID, settings: services.settings())
    }

    // MARK: Start

    private func start(_ hotkey: DictationHotkey) {
        guard phase == .idle else { return }

        // Checks that would only fail later, with nothing to show for it.
        if MicrophonePermission.status == .denied || MicrophonePermission.status == .restricted {
            hotkeys.recordingEnded()
            showError("Microphone access is off",
                      detail: "Allow devshout in System Settings → Privacy & Security → Microphone.")
            return
        }
        if let problem = services.engines.selectedModelProblem {
            hotkeys.recordingEnded()
            showError(problem.title, detail: problem.detail)
            return
        }

        onWillStart?()
        let settings = services.settings()
        let mode = resolveMode(for: hotkey)
        let front = FrontmostApp.current
        let target = front.map { TargetApp(bundleID: $0.bundleID, name: $0.name) }

        let engine = services.engines.engine
        let vad = services.vad
        let glossary = services.glossary
        let gate = LockedBox(true)
        deliveryGate = gate
        cancelRequested = false
        let maxChunk = engine.maxChunkDuration
        let dependencies = DictationDependencies(
            recorder: services.recorder,
            engine: engine,
            cleaner: services.claude.cleaner,
            deliverer: GatedDeliverer(inner: services.deliverer, isOpen: gate),
            history: services.history,
            planChunks: { samples in try await DictationController.planChunks(samples, vad: vad, maxChunkDuration: maxChunk) },
            stitch: { Stitcher.stitch($0) },
            fixText: { glossary.fix($0) },
            glossaryForClaude: { glossary.forClaude },
            vocabularyPrompt: { glossary.whisperPrompt() }
        )
        let session = DictationSession(dependencies: dependencies, settings: settings)
        let token = UUID()
        self.token = token
        self.session = session
        phase = .starting

        services.levelMeter.setPaused(true)
        services.recorder.deviceUID = settings.inputDeviceUID
        pill.showsLiveText = settings.showLivePreview
        pill.begin(mode: mode)
        panel.present()
        services.sounds.play(.start)
        menuBar.isRecording = true
        menuBar.isWorking = false

        // Follow the session's states for the pill (terminal states are handled by finish()).
        Task {
            for await state in session.states {
                guard self.token == token else { return }
                self.apply(state)
            }
        }

        startTask = Task {
            do {
                try await session.start(mode: mode, targetApp: target)
                guard self.token == token, self.phase == .starting else { return }
                self.phase = .recording
            } catch {
                guard self.token == token else { return }
                self.startFailed(error)
            }
        }
    }

    private func startFailed(_ error: Error) {
        let message = ErrorText.describe(error)
        let wasCancelled = cancelRequested
        endDictation()
        // Already cancelled (Esc while the microphone was still starting): nothing more to say.
        guard !wasCancelled else { return }
        services.sounds.play(.cancel)
        showError("Couldn't start recording", detail: message)
    }

    // MARK: Stop, cancel, switch

    private func stop() {
        guard isRecording, let session else { return }
        let token = token
        phase = .finishing
        services.sounds.play(.stop)
        menuBar.isRecording = false
        menuBar.isWorking = true
        pill.recordingStopped(duration: Date().timeIntervalSince(pill.startedAt))
        pill.phase = .transcribing(remaining: nil)
        services.levelMeter.setPaused(false)
        let started = startTask
        stopTask = Task {
            // stop() before start() reached the session would be refused; let start finish first.
            await started?.value
            let result = await session.stop()
            guard self.token == token else { return }
            self.finish(result)
        }
    }

    private func cancel() {
        guard phase != .idle, let session, !cancelRequested else { return }
        cancelRequested = true
        services.sounds.play(.cancel)
        menuBar.isRecording = false
        panel.dismiss(after: 0)

        if phase == .finishing {
            // Recording already stopped and the engine or Claude is still working: let go of it now. The session
            // finishes in the background (history keeps the audio and any text), but its result is never pasted.
            // (Deliberately not cancelling stopTask: that would cut the transcription short and save it as failed.)
            deliveryGate.value = false
            endDictation()
            return
        }

        let token = token
        phase = .finishing
        let started = startTask
        Task {
            await started?.value
            let result = await session.cancel()
            guard self.token == token else { return }
            self.finish(result)
        }
    }

    private func switchMode(to hotkey: DictationHotkey) {
        guard isRecording, let session else { return }
        let mode = resolveMode(for: hotkey)
        pill.mode = mode
        Task { _ = await session.setMode(mode) }
    }

    private func pasteRawNow() {
        guard let session else { return }
        Task { await session.pasteRawNow() }
    }

    // MARK: States → pill

    private func apply(_ state: SessionState) {
        switch state {
        case .idle, .recording:
            break
        case .transcribing:
            if case .transcribing = pill.phase {} else { pill.phase = .transcribing(remaining: nil) }
        case .cleaning(let model):
            pill.phase = .cleaning(model: model)
            setReturnKeyEnabled(true)
        case .delivering, .finished, .cancelled, .failed:
            setReturnKeyEnabled(false)
        }
    }

    /// While Claude is tidying, ⌥Return means "Paste raw now". Plain Return is left alone: swallowing it system-wide
    /// for up to 45 s would break typing in a terminal or chat box meanwhile.
    private func setReturnKeyEnabled(_ enabled: Bool) {
        if enabled {
            guard returnKeyTask == nil else { return }
            let events = KeyboardShortcuts.events(for: KeyboardShortcuts.Shortcut(.return, modifiers: [.option]))
            returnKeyTask = Task {
                for await event in events where event == .keyDown {
                    self.pasteRawNow()
                }
            }
        } else {
            returnKeyTask?.cancel()
            returnKeyTask = nil
        }
    }

    private func finish(_ result: DictationResult?) {
        guard let result else {
            // The session wasn't recording after all (start failed and was reported already).
            if phase != .idle { endDictation() }
            if !panelIsBusy { panel.dismiss(after: 0) }
            return
        }

        if let error = result.cleanError { services.claude.handle(error) }
        setReturnKeyEnabled(false)
        noticeTask?.cancel()
        pill.notice = nil

        switch result.state {
        case .finished(let outcome, let usedRaw, let reason, _):
            var shownOutcome = outcome
            let rec = result.recording
            if tryIt.isActive() {
                // The Try it box is devshout's own window, where the paste is skipped on purpose.
                let raw = rec.transcript ?? ""
                let cleaned = usedRaw || rec.mode == .raw ? nil : rec.deliveredText
                tryIt.deliver(raw, cleaned, rec.deliveredText ?? raw)
                if case .copiedOnly = outcome { shownOutcome = .pasted(appName: "the Try it box") }
            }
            if usedRaw {
                pill.phase = .fallback(reason: fallbackReason(reason, error: result.cleanError), outcome: shownOutcome)
            } else {
                pill.phase = .done(shownOutcome)
            }
            if let saveError = result.saveError { pill.notice = "Not saved to history: \(saveError)" }
            switch (usedRaw, shownOutcome) {
            case (false, .pasted): panel.dismiss(after: 1.2)
            case (_, .failed): panel.dismiss(after: 4)
            default: panel.dismiss(after: 3)
            }
        case .cancelled:
            panel.dismiss(after: 0)
        case .failed(let stage, let message):
            let title: String
            switch stage {
            case .recording: title = "Couldn't record"
            case .transcribing: title = message.hasPrefix("No speech") ? "No speech detected" : "Couldn't transcribe"
            case .cleaning, .delivering, .saving: title = "Something went wrong"
            }
            pill.phase = .error(message: title)
            let saved = result.saveError == nil ? " The audio is saved in history." : ""
            pill.notice = message.hasPrefix("No speech") ? "Nothing was pasted.\(saved)" : message + saved
            panel.dismiss(after: 4)
        case .idle, .recording, .transcribing, .cleaning, .delivering:
            panel.dismiss(after: 1)
        }

        endDictation()
        onFinished?()
    }

    /// "Connect Claude to tidy" reads better than "Claude isn't connected" when that's the reason.
    private func fallbackReason(_ reason: String?, error: CleanError?) -> String {
        switch error {
        case .notConnected?, .claudeNotFound?:
            return services.claude.rawFallbackHint ?? reason ?? "Claude wasn't used"
        case .authFailed?:
            return "Reconnect Claude to tidy"
        case let error?:
            return ErrorText.describe(error)
        case nil:
            return reason ?? "Claude wasn't used"
        }
    }

    private var panelIsBusy: Bool {
        switch pill.phase {
        case .error, .done, .fallback: return true
        default: return false
        }
    }

    private func endDictation() {
        phase = .idle
        session = nil
        startTask = nil
        stopTask = nil
        cancelRequested = false
        setReturnKeyEnabled(false)
        token = UUID()
        hotkeys.recordingEnded()
        menuBar.isRecording = false
        menuBar.isWorking = false
        services.levelMeter.setPaused(false)
        services.engines.dictationEnded()
    }

    // MARK: Messages

    /// A problem before any recording started: show it in the pill for a few seconds.
    private func showError(_ title: String, detail: String) {
        pill.begin(mode: services.settings().defaultMode)
        pill.phase = .error(message: title)
        pill.notice = detail
        panel.present()
        panel.dismiss(after: 4)
    }

    /// A second line on the pill for a moment, without disturbing what it shows.
    private func showNotice(_ text: String) {
        pill.notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, self.pill.notice == text else { return }
            self.pill.notice = nil
        }
    }

    // MARK: Chunk planning (off the main actor)

    /// Silero VAD over the whole recording, then ChunkPlanner (v0.1 transcribes after stop). If the VAD isn't
    /// loaded (its model couldn't be downloaded yet, say) or fails, every frame counts as speech, so the planner
    /// makes fixed-length chunks with overlaps and nothing is lost.
    nonisolated static func planChunks(_ samples: [Float], vad: SileroVAD,
                                       maxChunkDuration: TimeInterval) async throws -> [AudioChunk] {
        var probabilities: [Float] = []
        if await vad.isReady {
            do {
                await vad.reset()
                probabilities = try await vad.process(samples)
                if let last = try await vad.processRemainder() { probabilities.append(last) }
            } catch {
                probabilities = []
            }
        } else {
            // Don't make this dictation wait for a download: plan without it, and fetch the model for next time.
            Task.detached(priority: .utility) { try? await vad.prepare() }
        }
        return ChunkPlanner.plan(samples: samples, probabilities: probabilities, frameSize: vad.frameSize,
                                 maxChunkDuration: maxChunkDuration)
    }
}

/// Passes deliveries through until the dictation is cancelled; after that nothing touches the clipboard.
struct GatedDeliverer: Deliverer {
    let inner: any Deliverer
    let isOpen: LockedBox<Bool>

    func deliver(_ text: String) async -> DeliveryOutcome {
        guard isOpen.value else { return .failed(reason: "Cancelled") }
        return await inner.deliver(text)
    }
}
