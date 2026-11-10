// The frontmost app: for per-app default modes, history labels and "Pasted into Slack" (PLAN §3.1 step 1).
//
// Unverified on macOS (written on Linux):
// - The activation observer runs on the main queue and uses MainActor.assumeIsolated; that's safe because
//   the queue is .main, but it has not been run.

import AppKit
import Foundation

/// A snapshot of a running app. Sendable, so it can travel with a dictation session.
public struct FrontmostAppInfo: Sendable, Hashable {
    public var bundleID: String?
    public var name: String?
    public var processIdentifier: pid_t

    public init(bundleID: String?, name: String?, processIdentifier: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.processIdentifier = processIdentifier
    }

    public init(_ app: NSRunningApplication) {
        self.init(bundleID: app.bundleIdentifier, name: app.localizedName, processIdentifier: app.processIdentifier)
    }

    /// Whether this is devshout itself.
    public var isDevshout: Bool { processIdentifier == ProcessInfo.processInfo.processIdentifier }
}

/// Tracks which app is in front. `current` is always live; `lastExternal` is the most recent app in front that
/// wasn't devshout (use it as the dictation target when devshout's own window has just been used).
@MainActor
public final class FrontmostApp {
    public static let shared = FrontmostApp()

    /// Called on the main actor whenever another app becomes active.
    public var onChange: ((FrontmostAppInfo) -> Void)?

    public private(set) var lastExternal: FrontmostAppInfo?

    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var continuations: [UUID: AsyncStream<FrontmostAppInfo>.Continuation] = [:]

    public init() {
        if let current = Self.current, !current.isDevshout { lastExternal = current }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let info = FrontmostAppInfo(app)
            MainActor.assumeIsolated { self?.didActivate(info) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The app in front right now.
    public static var current: FrontmostAppInfo? {
        NSWorkspace.shared.frontmostApplication.map { FrontmostAppInfo($0) }
    }

    /// Activations as a stream (ends when the consumer stops iterating).
    public func changes() -> AsyncStream<FrontmostAppInfo> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FrontmostAppInfo>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    /// The icon of a running app, or of an installed app by bundle ID (for the Apps settings table and history).
    public static func icon(for info: FrontmostAppInfo) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: info.processIdentifier)?.icon { return icon }
        guard let bundleID = info.bundleID else { return nil }
        return icon(forBundleID: bundleID)
    }

    public static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The display name of an installed app by bundle ID.
    public static func name(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func didActivate(_ info: FrontmostAppInfo) {
        if !info.isDevshout { lastExternal = info }
        onChange?(info)
        for continuation in continuations.values { continuation.yield(info) }
    }
}
