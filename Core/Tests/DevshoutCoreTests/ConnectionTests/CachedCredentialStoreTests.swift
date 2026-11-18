import Foundation
import Testing
@testable import DevshoutCore

@Suite struct CachedCredentialStoreTests {
    /// Counts reads, and can be told to fail.
    final class CountingStore: CredentialStore, @unchecked Sendable {
        struct Refused: Error {}
        private let lock = NSLock()
        private var stored: ClaudeCredential?
        private var loadCount = 0
        private var failing = false

        init(_ stored: ClaudeCredential? = nil) { self.stored = stored }

        var loads: Int { lock.withLock { loadCount } }
        func setFailing(_ value: Bool) { lock.withLock { failing = value } }

        func load() throws -> ClaudeCredential? {
            try lock.withLock {
                loadCount += 1
                if failing { throw Refused() }
                return stored
            }
        }

        func save(_ credential: ClaudeCredential) throws { lock.withLock { stored = credential } }
        func delete() throws { lock.withLock { stored = nil } }
    }

    static let token = ClaudeCredential(token: "fake-token-for-tests", createdAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func readsTheWrappedStoreOnce() throws {
        let inner = CountingStore(Self.token)
        let store = CachedCredentialStore(inner)
        for _ in 0..<5 { #expect(try store.load() == Self.token) }
        #expect(inner.loads == 1)
    }

    @Test func rememberingThereIsNoTokenIsAlsoOneRead() throws {
        let inner = CountingStore()
        let store = CachedCredentialStore(inner)
        #expect(try store.load() == nil)
        #expect(try store.load() == nil)
        #expect(inner.loads == 1)
    }

    @Test func aRefusedReadIsNotRetriedUntilAskedTo() throws {
        let inner = CountingStore(Self.token)
        inner.setFailing(true)
        let store = CachedCredentialStore(inner)
        #expect(throws: CountingStore.Refused.self) { try store.load() }
        #expect(throws: CountingStore.Refused.self) { try store.load() }
        #expect(inner.loads == 1)

        inner.setFailing(false)
        store.retryAfterFailure()
        #expect(try store.load() == Self.token)
        #expect(inner.loads == 2)

        // Nothing failed, so asking to try again changes nothing.
        store.retryAfterFailure()
        #expect(try store.load() == Self.token)
        #expect(inner.loads == 2)
    }

    @Test func savingAndDeletingUpdateWhatIsRemembered() throws {
        let inner = CountingStore()
        let store = CachedCredentialStore(inner)
        #expect(try store.load() == nil)
        try store.save(Self.token)
        #expect(try store.load() == Self.token)
        #expect(try inner.load() == Self.token)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(inner.loads == 2) // the first read, and this test's own check of the wrapped store
    }

    @Test func emptyStoreNeverHoldsAnything() throws {
        let store = EmptyCredentialStore()
        try store.save(Self.token)
        #expect(try store.load() == nil)
    }
}
