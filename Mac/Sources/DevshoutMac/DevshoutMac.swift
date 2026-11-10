import DevshoutCore
import FluidAudio
import KeyboardShortcuts
import WhisperKit

/// macOS implementations of the Core protocols live in the folders next to this file:
/// Audio/ (mic capture, resampling, WAV, VAD), Engines/ (Parakeet, Whisper), System/ (hotkeys, paste, permissions),
/// Claude/ (setup-token PTY flow, Keychain, connection status).
public enum DevshoutMac {
    public static let version = "0.1.0"
}
