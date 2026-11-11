// Claude: finding Claude Code (ClaudeLocator + ClaudeInstallationCache), installing it (ClaudeInstaller), the
// setup-token connection (ClaudeConnection + KeychainCredentialStore), the clean-up itself (ClaudeCLICleaner with
// devshout's own CLAUDE_CONFIG_DIR and working directory) and Test Connection. Keeps `ClaudeViewModel` current.
//
// Subscription only: the token comes from `claude setup-token` and is passed as CLAUDE_CODE_OAUTH_TOKEN. There is
// no API-key option, and `--bare` is never used (it ignores OAuth tokens).

import AppKit
import Combine
import DevshoutCore
import DevshoutMac
import Foundation

@MainActor
final class ClaudeController {
    let connection: ClaudeConnection
    let cleaner: ClaudeCLICleaner
    /// Writes the voice calibration's glossary sentences: the same token, gate and folders as `cleaner`.
    let sentenceWriter: ClaudeSentenceWriter
    /// The same clean-up, with whatever token is saved (not gated): Test Connection must work after a refusal.
    private let testCleaner: ClaudeCLICleaner
    private let cache: ClaudeInstallationCache
    private let store: KeychainCredentialStore
    private let installer: ClaudeInstaller
    private let model: ClaudeViewModel
    private let defaults: UserDefaults
    /// Read by the cleaner (off the main actor): whether the connection may be used for clean-up right now.
    private let canClean = LockedBox(false)

    /// Persists a `claude` path picked by hand.
    var onPathOverride: ((String?) -> Void)?

    private var isDetecting = false
    private var lastLocateError: Error?
    /// A sign-in that failed while its sheet was open: the sheet stays up with this message until cancelled.
    private var signInFailure: String?
    private var cancellables: Set<AnyCancellable> = []
    private var flowCancellable: AnyCancellable?
    private var observedFlow: SetupTokenFlow?

    init(paths: AppPaths, pathOverride: String?, model: ClaudeViewModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        installer = ClaudeInstaller()
        let locator = ClaudeLocator(userOverride: pathOverride.map { URL(fileURLWithPath: $0) })
        let cache = ClaudeInstallationCache(locator: locator)
        self.cache = cache
        let store = KeychainCredentialStore()
        self.store = store
        let gate = canClean
        cleaner = ClaudeCLICleaner(
            installation: { try await cache.installation() },
            credential: {
                // Expired, refused or disconnected: no token, so Tidy and Structure paste the raw text.
                guard gate.value else { return nil }
                return try store.load()
            },
            configDirectory: paths.claudeConfig,
            workingDirectory: paths.claudeWorkingDirectory
        )
        sentenceWriter = ClaudeSentenceWriter(
            installation: { try await cache.installation() },
            credential: {
                guard gate.value else { return nil }
                return try store.load()
            },
            configDirectory: paths.claudeConfig,
            workingDirectory: paths.claudeWorkingDirectory
        )
        testCleaner = ClaudeCLICleaner(
            installation: { try await cache.installation() },
            credential: { try store.load() },
            configDirectory: paths.claudeConfig,
            workingDirectory: paths.claudeWorkingDirectory
        )
        // `locate` is filled in below, once `self` exists.
        var locate: (() async -> DevshoutCore.ClaudeInstallation?)?
        connection = ClaudeConnection(store: store, locate: { await locate?() })
        locate = { [weak self] in await self?.locateInstallation() }

        model.usesRawOnly = defaults.bool(forKey: AppDefaultsKey.claudeRawOnly)
        model.actions = ClaudeViewModel.Actions(
            detect: { [weak self] in self?.detect() },
            installForMe: { [weak self] in self?.installer.install() },
            openInstallerInTerminal: { [weak self] in self?.openInstallerInTerminal() },
            setClaudePath: { [weak self] url in self?.setClaudePath(url) },
            connect: { [weak self] in self?.connect() },
            submitCode: { [weak self] code in self?.connection.setupFlow?.submitCode(code) },
            cancelSignIn: { [weak self] in self?.cancelSignIn() },
            useToken: { [weak self] token in self?.useToken(token) },
            disconnect: { [weak self] in self?.disconnect() },
            test: { [weak self] in self?.runTest() },
            setRawOnly: { [weak self] rawOnly in self?.defaults.set(rawOnly, forKey: AppDefaultsKey.claudeRawOnly) }
        )

        // objectWillChange fires before the change lands: look on the next turn of the main queue.
        connection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.connectionChanged() }
            .store(in: &cancellables)
        installer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        installer.onFinished = { [weak self] succeeded in
            guard let self else { return }
            if succeeded { self.detect() } else { self.render() }
        }
        render()
    }

    /// Whether Claude can be used right now (installed, connected, token not refused or expired).
    var canCleanNow: Bool { canClean.value }

    /// The hint the overlay shows when Tidy or Structure pasted raw because of the connection.
    var rawFallbackHint: String? { connection.state.rawFallbackHint }

    // MARK: Status

    /// Look for `claude` again and re-read the token (launch, opening Settings, after installing).
    func detect() {
        guard !isDetecting else { return }
        isDetecting = true
        render()
        Task {
            await self.connection.refresh()
            self.isDetecting = false
            self.render()
        }
    }

    /// The pipeline saw a clean-up fail on authentication: Tidy and Structure paste raw until Reconnect.
    func markAuthFailed(_ message: String) {
        connection.markAuthFailed(message)
        render()
    }

    /// The pipeline couldn't run `claude` at all: look for it again.
    func claudeWentMissing() {
        Task {
            await self.cache.invalidate()
            self.detect()
        }
    }

    private func locateInstallation() async -> DevshoutCore.ClaudeInstallation? {
        await cache.invalidate()
        do {
            let found = try await cache.installation()
            lastLocateError = nil
            return found
        } catch {
            lastLocateError = error
            return nil
        }
    }

    // MARK: Actions

    private func openInstallerInTerminal() {
        do {
            try installer.openInTerminal()
        } catch {
            model.installLog += "\nCouldn't open Terminal: \(ErrorText.describe(error))\n"
        }
    }

    private func setClaudePath(_ url: URL) {
        onPathOverride?(url.path)
        Task {
            await self.cache.setUserOverride(url)
            self.detect()
        }
    }

    private func connect() {
        signInFailure = nil
        if connection.connect() == nil {
            // Claude Code isn't installed (or wasn't found): offer to install it.
            model.isInstallSheetPresented = true
            render()
            return
        }
        // The flow can fail synchronously (the pseudo-terminal didn't start): look at it now, not on the next turn.
        observeCurrentFlow()
        flowChanged()
    }

    private func cancelSignIn() {
        signInFailure = nil
        if let flow = connection.setupFlow, flow.status.isInProgress { flow.cancel() }
        render()
    }

    private func useToken(_ token: String) {
        do {
            try connection.savePastedToken(token)
            signInFailure = nil
            model.pasteTokenError = nil
        } catch {
            model.pasteTokenError = ErrorText.describe(error)
        }
        render()
    }

    private func disconnect() {
        signInFailure = nil
        do {
            try connection.disconnect()
        } catch {
            model.pasteTokenError = connection.lastError ?? ErrorText.describe(error)
        }
        render()
    }

    /// One tiny Tidy request through the real clean-up path, timed.
    private func runTest() {
        var config = ModeConfig.defaults[.tidy] ?? ModeConfig(id: .tidy, claudeModel: "haiku", timeout: 30)
        config.timeout = max(config.timeout, 30)
        config.customInstructions = nil
        let cleaner = testCleaner
        let started = Date()
        Task {
            do {
                _ = try await cleaner.clean("so this is just a quick test of devshout to check that tidy works",
                                            mode: config, glossary: "")
                self.model.test = .succeeded(elapsed: Date().timeIntervalSince(started), at: Date())
                self.clearAuthFailure()
            } catch let error as CleanError {
                self.model.test = .failed(message: ErrorText.describe(error))
                self.handle(error)
            } catch {
                self.model.test = .failed(message: ErrorText.describe(error))
            }
        }
    }

    /// The saved token just worked: forget an earlier refusal so Tidy and Structure use Claude again.
    /// (ClaudeConnection keeps the refusal in UserDefaults under this key; it has no public way to clear it short
    /// of saving a new token.)
    private func clearAuthFailure() {
        guard case .needsReconnect(.authFailed) = connection.state else { return }
        defaults.removeObject(forKey: "claude.authFailure")
        connection.recheckExpiry()
        render()
    }

    /// Follow-up on a clean-up failure (from a dictation or the test).
    func handle(_ error: CleanError) {
        switch error {
        case .authFailed(let message):
            markAuthFailed(message)
        case .claudeNotFound:
            claudeWentMissing()
        default:
            break
        }
    }

    // MARK: Rendering

    private func connectionChanged() {
        observeCurrentFlow()
        render()
    }

    /// Follow the current setup flow too (connect() makes a new one each time).
    private func observeCurrentFlow() {
        guard connection.setupFlow !== observedFlow else { return }
        observedFlow = connection.setupFlow
        flowCancellable = observedFlow?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flowChanged() }
    }

    private func flowChanged() {
        if let flow = connection.setupFlow, case .failed(let message) = flow.status {
            signInFailure = message.isEmpty ? "Sign-in didn't finish." : message
        }
        render()
    }

    /// Maps the connection, flow and installer onto what the views show.
    private func render() {
        canClean.value = connection.state.canClean
        let install = installStatus()
        if model.install != install { model.install = install }
        let account = accountStatus()
        if model.account != account { model.account = account }
        if installer.log != model.installLog, installer.status != .idle { model.installLog = installer.log }
    }

    private func installStatus() -> ClaudeInstallStatus {
        switch installer.status {
        case .running: return .installing
        case .failed(let message): return .installFailed(message: message)
        default: break
        }
        if isDetecting || connection.state == .checking { return .detecting }
        if let found = connection.installation {
            return .found(ClaudeInstallation(path: found.url.path, version: found.displayVersion,
                                             meetsMinimum: found.meetsMinimum,
                                             minimumVersion: ClaudeLocator.minimumVersion.description))
        }
        if let error = lastLocateError as? ClaudeLocatorError, case .tooOld(let path, let version, let minimum) = error {
            return .found(ClaudeInstallation(path: path, version: version.description, meetsMinimum: false,
                                             minimumVersion: minimum.description))
        }
        return .notFound
    }

    private func accountStatus() -> ClaudeAccountStatus {
        if let flow = connection.setupFlow {
            switch flow.status {
            case .starting:
                return .signingIn(ClaudeSignInProgress())
            case .waitingForBrowser(let url):
                return .signingIn(ClaudeSignInProgress(signInURL: url))
            case .needsCode(let url):
                return .signingIn(ClaudeSignInProgress(signInURL: url, needsCode: true))
            case .verifyingCode:
                return .signingIn(ClaudeSignInProgress(needsCode: true, isSubmittingCode: true))
            default:
                break
            }
        }
        if let signInFailure {
            return .signingIn(ClaudeSignInProgress(
                message: "\(signInFailure) Try again, or paste a token made in Terminal below."))
        }
        switch connection.state {
        case .checking:
            return .unknown
        case .notInstalled, .notConnected:
            return .notConnected
        case .connected(let createdAt, _):
            return .connected(tokenCreatedAt: createdAt)
        case .needsReconnect:
            return .needsReconnect(reason: connection.state.detail)
        }
    }
}
