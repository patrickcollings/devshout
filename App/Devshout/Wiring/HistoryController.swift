// What Settings → History can do with a recording beyond listing it: play its audio, and send its transcript
// through Claude again in another mode.
//
// AppCoordinator points HistoryViewModel's actions at this class; this class tells the model what happened
// (`playbackStarted`, `rerunFinished`, …). Nothing here pastes or touches the clipboard.

import DevshoutCore
import DevshoutMac
import Foundation

@MainActor
final class HistoryController {
    private let model: HistoryViewModel
    private let history: HistoryStore
    private let claude: ClaudeController
    private let glossary: GlossaryState
    private let settings: () -> AppSettings
    private let player = AudioFilePlayer()

    /// Whether the microphone is recording a dictation right now (playback would be picked up by it).
    var isRecording: () -> Bool = { false }
    /// A recording changed on disk (Settings → Privacy shows the size of the history).
    var onChange: () -> Void = {}

    private var playingID: UUID?
    /// Changes with every play and stop, so a file found after the user moved on is not played.
    private var playRequest = UUID()

    /// Re-runs through Claude that haven't finished, by recording.
    private var rerunTasks: [UUID: Task<Void, Never>] = [:]

    init(model: HistoryViewModel, history: HistoryStore, claude: ClaudeController, glossary: GlossaryState,
         settings: @escaping () -> AppSettings) {
        self.model = model
        self.history = history
        self.claude = claude
        self.glossary = glossary
        self.settings = settings
        player.onFinished = { [weak self] in self?.playerFinished() }
    }

    // MARK: Playback

    /// Plays the recording's audio.wav from the start, replacing whatever was playing.
    func play(_ id: UUID) {
        stopPlayback()
        guard !isRecording() else {
            model.playbackUnavailable(id, message: HistoryText.cannotPlayWhileDictating)
            return
        }
        let request = UUID()
        playRequest = request
        let history = history
        Task {
            // Finding the folder reads the Recordings directory: off the main actor.
            let url = await Task.detached(priority: .userInitiated) { history.audioURL(for: id) }.value
            guard self.playRequest == request else { return }
            guard !self.isRecording() else {
                self.model.playbackUnavailable(id, message: HistoryText.cannotPlayWhileDictating)
                return
            }
            guard let url else {
                self.model.playbackUnavailable(id, message: HistoryText.audioMissing)
                return
            }
            do {
                try self.player.play(url)
                self.playingID = id
                self.model.playbackStarted(id)
            } catch {
                NSLog("devshout: play \(url.path): \(error)")
                self.model.playbackUnavailable(id, message: HistoryText.audioUnplayable)
            }
        }
    }

    /// Stops the audio and forgets a play that hasn't started yet. Safe to call at any time, from any event:
    /// the Stop button, another recording on show, the Settings window closing, a dictation starting.
    func stopPlayback() {
        playRequest = UUID()
        player.stop()
        if let id = playingID {
            playingID = nil
            model.playbackEnded(id)
        }
    }

    private func playerFinished() {
        guard let id = playingID else { return }
        playingID = nil
        model.playbackEnded(id)
    }

    // MARK: Re-run

    /// Sends the recording's transcript through Claude again in `mode`, with the cleaner, glossary and mode
    /// settings a dictation would use now, and adds the result to the recording as a new version. Nothing is
    /// pasted or copied.
    func rerun(_ id: UUID, mode: ModeID) {
        guard rerunTasks[id] == nil, mode.usesClaude else { return }
        let current = settings()
        let config = current.config(for: mode)
        // For the messages, and for the version's own record of a custom mode's name.
        let descriptor = current.descriptor(for: mode)
        let modeName = current.storedName(for: mode)
        let cleaner = claude.cleaner
        let glossaryText = glossary.forClaude
        let history = history
        model.rerunStarted(id, mode: mode, model: config.claudeModel)
        rerunTasks[id] = Task {
            // What the pane should say when this ends other than with a new version; nil for a cancelled run.
            var failure: String?
            do {
                // From disk rather than the list: the list can be a moment behind.
                let recording = try await Task.detached(priority: .userInitiated) { try history.load(id) }.value
                if let transcript = recording?.transcript,
                   !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let result = try await cleaner.clean(transcript, mode: config, glossary: glossaryText)
                    try Task.checkCancellation()
                    if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw CleanError.rejectedOutput(reason: "empty output")
                    }
                    let version = CleanVersion(result, mode: mode, modeName: modeName, createdAt: Date())
                    let updated = try await Task.detached(priority: .userInitiated) {
                        try history.appendVersion(version, to: id)
                    }.value
                    self.rerunTasks[id] = nil
                    self.model.rerunFinished(updated)
                    self.onChange()
                    return
                }
                failure = HistoryText.rerunNothingToSend(mode: descriptor)
            } catch let error as CleanError {
                // A cancelled run comes back as a failed process: that isn't a failure to report.
                if !Task.isCancelled {
                    self.claude.handle(error)
                    failure = HistoryText.rerunFailed(mode: descriptor, error)
                }
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = HistoryText.rerunNotSaved(mode: descriptor, detail: ErrorText.describe(error))
            }
            self.rerunTasks[id] = nil
            if let failure {
                self.model.rerunFailed(id, mode: mode, message: failure)
            } else {
                self.model.rerunCancelled(id)
            }
        }
    }

    /// Stops the `claude` process of a re-run. The pane shows it as running until the process has gone.
    func cancelRerun(_ id: UUID) {
        rerunTasks[id]?.cancel()
    }

    /// The recording is being deleted: let go of it.
    func forget(_ id: UUID) {
        if playingID == id { stopPlayback() }
        cancelRerun(id)
    }
}
