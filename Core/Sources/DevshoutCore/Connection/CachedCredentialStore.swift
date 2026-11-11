import Foundation

/// Reads the credential from the wrapped store once and remembers the answer for the life of the process.
///
/// Every read of the macOS Keychain by an app that isn't on the item's access list shows a permission prompt,
/// and devshout read the token at launch, before every clean-up, for every test and once a day. Reading once
/// means one prompt at most per launch. A refused or failed read is remembered too, so nothing prompts again
/// behind the user's back; `forget()` (an explicit "try again") clears it.
public final class CachedCredentialStore: CredentialStore, @unchecked Sendable {
    private enum State {
        case unread
        case loaded(ClaudeCredential?)
        case failed(any Error)
    }

    private let inner: any CredentialStore
    private let lock = NSLock()
    private var state = State.unread

    public init(_ inner: any CredentialStore) {
        self.inner = inner
    }

    /// The lock is held while the wrapped store reads, so callers that arrive together share one read (and one
    /// prompt) rather than each starting their own.
    public func load() throws -> ClaudeCredential? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .loaded(let credential):
            return credential
        case .failed(let error):
            throw error
        case .unread:
            do {
                let credential = try inner.load()
                state = .loaded(credential)
                return credential
            } catch {
                state = .failed(error)
                throw error
            }
        }
    }

    public func save(_ credential: ClaudeCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        try inner.save(credential)
        state = .loaded(credential)
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        try inner.delete()
        state = .loaded(nil)
    }

    /// Read from the wrapped store again on the next `load()`.
    public func forget() {
        lock.lock()
        state = .unread
        lock.unlock()
    }

    /// Like `forget()`, but only when the last read failed: for when the user asks to try again. A token that
    /// was read successfully stays remembered, so trying again never costs a second prompt.
    public func retryAfterFailure() {
        lock.lock()
        if case .failed = state { state = .unread }
        lock.unlock()
    }
}

/// A store with nothing in it that can't be written to: devshout behaves as if Claude were not connected.
/// Used when launching the app only to look at a screen, so the Keychain is never touched.
public struct EmptyCredentialStore: CredentialStore {
    public init() {}
    public func load() throws -> ClaudeCredential? { nil }
    public func save(_ credential: ClaudeCredential) throws {}
    public func delete() throws {}
}
