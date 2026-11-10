// Microphone permission (TCC) status and request, and a link to the right System Settings pane.
//
// Unsure on macOS (not compiled in CI yet):
// - The pane URL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" works on macOS 13–15;
//   macOS 26 may prefer "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone".
//   We try the long-standing one first and fall back to the newer one.
import AppKit
import AVFoundation
import Foundation

public enum MicrophonePermission {
    public enum Status: String, Sendable, Hashable {
        case notDetermined
        case authorised
        case denied
        /// Blocked by a configuration profile or parental controls: the user can't change it.
        case restricted
    }

    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorised
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public static var isAuthorised: Bool { status == .authorised }

    /// Shows the system prompt the first time; afterwards it answers straight away with the stored choice.
    /// Needs `NSMicrophoneUsageDescription` in Info.plist, or the process is killed.
    public static func request() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let newerSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!

    /// Opens System Settings → Privacy & Security → Microphone.
    @MainActor
    @discardableResult
    public static func openSystemSettings() -> Bool {
        NSWorkspace.shared.open(settingsURL) || NSWorkspace.shared.open(newerSettingsURL)
    }
}
