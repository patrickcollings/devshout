// What Settings → History can do with a recording beyond listing it: play its audio.
//
// AppCoordinator points HistoryViewModel's actions at this class; this class tells the model what happened
// (`playbackStarted`, …). Nothing here pastes or touches the clipboard.

import DevshoutCore
import DevshoutMac
import Foundation

@MainActor
final class HistoryController {
    private let model: HistoryViewModel
    private let history: HistoryStore
    private let player = AudioFilePlayer()

    /// Whether the microphone is recording a dictation right now (playback would be picked up by it).
    var isRecording: () -> Bool = { false }

    private var playingID: UUID?
    /// Changes with every play and stop, so a file found after the user moved on is not played.
    private var playRequest = UUID()

    init(model: HistoryViewModel, history: HistoryStore) {
        self.model = model
        self.history = history
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

    /// The recording is being deleted: let go of it.
    func forget(_ id: UUID) {
        if playingID == id { stopPlayback() }
    }
}
