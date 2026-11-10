// Plays one audio file at a time through the default output: a recording's audio.wav in Settings → History.
//
// Nothing here stops by itself except reaching the end of the file. The owner calls `stop()` from explicit events
// (another recording selected, the window closing, a dictation starting); `stop()` is safe to call at any time.

import AVFoundation
import Foundation

public enum AudioFilePlayerError: Error, LocalizedError, Sendable {
    /// The file opened but AVAudioPlayer refused to play it (no output device, say).
    case couldNotStart

    public var errorDescription: String? {
        switch self {
        case .couldNotStart: "The audio couldn't be played"
        }
    }
}

@MainActor
public final class AudioFilePlayer: NSObject {
    /// The file played to its end, or couldn't be decoded part-way. Not called for `stop()`.
    public var onFinished: (() -> Void)?

    private var player: AVAudioPlayer?

    public override init() {
        super.init()
    }

    public var isPlaying: Bool { player?.isPlaying ?? false }

    /// Stops whatever is playing and plays the file from its start. Throws when the file can't be opened or played.
    public func play(_ url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw AudioFilePlayerError.couldNotStart }
        self.player = player
    }

    /// Stops playback. Does nothing when nothing is playing.
    public func stop() {
        guard let player else { return }
        // Dropped first, so a "finished" callback already on its way is ignored.
        self.player = nil
        player.delegate = nil
        player.stop()
    }

    private func finished(_ id: ObjectIdentifier) {
        // Only for the player that is current: a stopped or replaced one says nothing.
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        onFinished?()
    }
}

extension AudioFilePlayer: AVAudioPlayerDelegate {
    // AVAudioPlayer doesn't promise a thread for these: hop to the main queue.
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finished(id) }
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finished(id) }
        }
    }
}
