// Small pieces the wiring shares: where devshout keeps its files, a lock-protected box for values that closures
// running off the main actor read, and the UserDefaults keys for flags that aren't part of settings.json.

import DevshoutCore
import Foundation

/// Everything under `~/Library/Application Support/devshout/` (PLAN §3.5).
struct AppPaths: Sendable {
    /// `~/Library/Application Support`.
    let applicationSupport: URL
    /// `~/Library/Application Support/devshout`.
    let root: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        applicationSupport = support
        root = support.appendingPathComponent("devshout", isDirectory: true)
    }

    var settings: URL { root.appendingPathComponent("settings.json", isDirectory: false) }
    var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    var glossary: URL { GlossaryFile.defaultURL(applicationSupport: applicationSupport) }
    /// `CLAUDE_CONFIG_DIR` for `claude -p`: devshout's own, empty config, so the user's hooks and CLAUDE.md never load.
    var claudeConfig: URL { root.appendingPathComponent("claude", isDirectory: true) }
    /// The empty working directory `claude -p` runs in.
    var claudeWorkingDirectory: URL { root.appendingPathComponent("claude-cwd", isDirectory: true) }
    /// Voice calibration: one folder per session, with its recordings and result.json.
    var calibration: URL { root.appendingPathComponent("Calibration", isDirectory: true) }
    var models: ModelLocations { ModelLocations(root: root.appendingPathComponent("Models", isDirectory: true)) }
    /// Scratch space for the level meter (its throwaway recordings are deleted when the meter stops).
    var meterScratch: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("devshout-meter", isDirectory: true)
    }

    func createFolders() {
        let fileManager = FileManager.default
        for folder in [root, recordings, claudeConfig, claudeWorkingDirectory, models.root] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// A value shared with closures that run on other actors (the dictation session, the paster, the cleaner).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Flags kept in UserDefaults rather than settings.json (they're about this Mac's set-up, not preferences).
enum AppDefaultsKey {
    static let onboardingCompleted = "onboarding.completed"
    static let claudeRawOnly = "claude.rawOnly"
}

enum ErrorText {
    /// A readable sentence for any error.
    static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription, !description.isEmpty {
            return description
        }
        if let error = error as? ClaudeLocatorError {
            switch error {
            case .notFound: return "Claude Code wasn't found"
            case .versionUnreadable(let path, _): return "Couldn't read the version of \(path)"
            case .tooOld(_, let found, let minimum): return "Claude Code \(found) is too old (needs \(minimum) or later)"
            }
        }
        return String(describing: error)
    }

    /// Why a clean-up failed, as the overlay and Settings say it.
    static func describe(_ error: CleanError) -> String {
        switch error {
        case .claudeNotFound: return "Claude Code wasn't found"
        case .notConnected: return "Claude isn't connected"
        case .authFailed: return "Claude didn't accept the token. Reconnect in Settings → Claude"
        case .timedOut(let after): return "Claude timed out after \(Int(after.rounded())) s"
        case .processFailed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Claude failed (exit code \(code))" : "Claude failed: \(trimmed)"
        case .rejectedOutput(let reason): return "Claude's output was rejected: \(reason)"
        }
    }
}
