// ClaudeConnection: the one object the app asks about Claude. Is Claude Code installed, is there a token, is it
// still good, and the actions (connect / reconnect, disconnect, paste a token).
//
// The state logic is in Core (ConnectionState.resolve, TokenHealth) and tested on Linux. Unsure / unverified on macOS:
// - Type-checked on Linux with a Combine stand-in, not built with the macOS SDK.
// - The daily expiry check uses a Timer on the main run loop (common modes), so it also fires while a menu is open.
// - An auth failure is remembered in UserDefaults (key below) against the token's createdAt, so it survives a relaunch
//   and a new token clears it.

import Combine
import DevshoutCore
import Foundation

@MainActor
public final class ClaudeConnection: ObservableObject {
    /// Finds `claude` and asks its version (built elsewhere: ClaudeLocator). Nil when it isn't installed.
    public typealias Locate = () async -> ClaudeInstallation?

    @Published public private(set) var state: ConnectionState = .checking
    /// The binary found by the last `refresh()`.
    @Published public private(set) var installation: ClaudeInstallation?
    /// The browser approval in progress (or last finished), for the connection sheet.
    @Published public private(set) var setupFlow: SetupTokenFlow?
    /// A problem reading or deleting the Keychain item, for Settings to show.
    @Published public private(set) var lastError: String?

    public let store: CredentialStore
    private let locate: Locate
    private let dateSource: DateSource
    private let defaults: UserDefaults
    private var dailyTimer: Timer?
    private var refreshing: Task<Void, Never>?

    static let authFailureKey = "claude.authFailure"

    public init(store: CredentialStore = KeychainCredentialStore(),
                dateSource: DateSource = SystemDateSource(),
                defaults: UserDefaults = .standard,
                locate: @escaping Locate) {
        self.store = store
        self.dateSource = dateSource
        self.defaults = defaults
        self.locate = locate
        startDailyCheck()
    }

    // MARK: Status

    /// Looks for `claude` again and re-reads the token. Call at launch, on opening Settings, after installing,
    /// and after a run fails because `claude` couldn't be found. Overlapping calls share one refresh.
    public func refresh() async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { @MainActor in
            let found = await self.locate()
            self.installation = found
            // The first Keychain read can wait on a permission prompt: do it off the main actor, so the app
            // stays usable meanwhile. A caching store then answers `recheckExpiry` from memory.
            if let cached = self.store as? CachedCredentialStore {
                await Task.detached { _ = try? cached.load() }.value
            }
            self.recheckExpiry()
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// Re-reads the token and re-evaluates its expiry without looking for `claude` again. Runs once a day by itself.
    public func recheckExpiry() {
        let credential = loadCredential()
        state = ConnectionState.resolve(
            isInstalled: installation != nil,
            credential: credential,
            authFailure: storedAuthFailure()?.message(for: credential),
            now: dateSource.now()
        )
    }

    /// The credential to pass to `claude -p` as CLAUDE_CODE_OAUTH_TOKEN, or nil when Tidy and Structure should
    /// paste raw (not installed, not connected, expired, or refused).
    public func credentialForCleanUp() -> ClaudeCredential? {
        guard state.canClean else { return nil }
        return loadCredential()
    }

    /// Called by the pipeline when a clean-up failed on authentication (`CleanError.authFailed`).
    /// Tidy and Structure paste raw until the user reconnects.
    public func markAuthFailed(_ reason: String) {
        if let credential = loadCredential() {
            let failure = ClaudeAuthFailure(credentialCreatedAt: credential.createdAt, message: reason)
            if let data = try? JSONEncoder().encode(failure) { defaults.set(data, forKey: Self.authFailureKey) }
        }
        state = .needsReconnect(reason: .authFailed(message: reason))
    }

    // MARK: Actions

    /// Starts the browser approval (`claude setup-token`). Returns the flow for the sheet to show, or nil when
    /// Claude Code isn't installed (state becomes `.notInstalled`).
    @discardableResult
    public func connect() -> SetupTokenFlow? {
        guard let installation else {
            state = .notInstalled
            return nil
        }
        setupFlow?.cancel()
        let flow = makeFlow()
        setupFlow = flow
        flow.start(claudeURL: installation.url)
        return flow
    }

    /// The one-click Reconnect: the same browser approval again. The old token stays until the new one is saved.
    @discardableResult
    public func reconnect() -> SetupTokenFlow? { connect() }

    /// Saves a token made with `claude setup-token` in Terminal. Throws `TokenValidationError` (with a message for
    /// the user) or a Keychain error.
    public func savePastedToken(_ text: String) throws {
        let flow = setupFlow ?? makeFlow()
        setupFlow = flow
        try flow.savePastedToken(text)
    }

    /// Opens `claude setup-token` in Terminal, for when the in-app flow fails. The user pastes the token back.
    public func openSetupTokenInTerminal() throws {
        guard let installation else {
            state = .notInstalled
            return
        }
        try (setupFlow ?? makeFlow()).openInTerminal(claudeURL: installation.url)
    }

    /// Forgets the token: deletes the Keychain item. (The token itself stays valid at Anthropic until it
    /// expires; it can't be revoked from here.)
    public func disconnect() throws {
        setupFlow?.cancel()
        setupFlow = nil
        do {
            try store.delete()
            lastError = nil
        } catch {
            lastError = "Couldn't remove the token from the Keychain: \(error.localizedDescription)"
            throw error
        }
        defaults.removeObject(forKey: Self.authFailureKey)
        recheckExpiry()
    }

    // MARK: Private

    private func makeFlow() -> SetupTokenFlow {
        let flow = SetupTokenFlow(store: store, dateSource: dateSource)
        flow.onSaved = { [weak self] _ in
            guard let self else { return }
            self.defaults.removeObject(forKey: Self.authFailureKey)
            self.lastError = nil
            self.recheckExpiry()
        }
        return flow
    }

    private func loadCredential() -> ClaudeCredential? {
        do {
            let credential = try store.load()
            lastError = nil
            return credential
        } catch {
            lastError = "Couldn't read the Claude token from the Keychain: \(error.localizedDescription)"
            return nil
        }
    }

    private func storedAuthFailure() -> ClaudeAuthFailure? {
        guard let data = defaults.data(forKey: Self.authFailureKey) else { return nil }
        return try? JSONDecoder().decode(ClaudeAuthFailure.self, from: data)
    }

    private func startDailyCheck() {
        let timer = Timer(timeInterval: TokenHealth.day, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckExpiry() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }
}
