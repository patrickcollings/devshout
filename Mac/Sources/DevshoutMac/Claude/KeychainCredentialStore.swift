// KeychainCredentialStore: keeps the Claude token (a JSON-encoded ClaudeCredential) as one generic-password item in
// the login Keychain of this Mac: service "app.devshout.mac.claude-token", account "default",
// accessible after first unlock, this device only (never synced to iCloud Keychain).
//
// Unsure / unverified on macOS:
// - Uses the file-based login keychain (no kSecUseDataProtectionKeychain): the data-protection keychain needs a
//   keychain-access-groups entitlement, which an ad-hoc signed app can't have (it fails with errSecMissingEntitlement).
//   kSecAttrAccessible is set anyway; on the file-based keychain macOS may ignore it.
// - The item's access list names the app that created it. An ad-hoc signed rebuild is a "different" app to the
//   Keychain, so macOS may ask once to allow access after each rebuild ("Always Allow" sorts it).

import DevshoutCore
import Foundation
import Security

public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "app.devshout.mac.claude-token"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String

    public init(service: String = KeychainCredentialStore.defaultService, account: String = KeychainCredentialStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    public func load() throws -> ClaudeCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: .read) }
        guard let data = item as? Data else { throw KeychainError(status: errSecDecode, operation: .read) }
        do {
            return try JSONDecoder().decode(ClaudeCredential.self, from: data)
        } catch {
            throw KeychainError(status: errSecDecode, operation: .read)
        }
    }

    public func save(_ credential: ClaudeCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus, operation: .save)
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "devshout: Claude token"
        add[kSecAttrDescription as String] = "Token from claude setup-token, used by devshout to tidy dictation"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus, operation: .save) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: .delete)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
    public enum Operation: String, Sendable {
        case read, save, delete
    }

    public let status: OSStatus
    public let operation: Operation

    public init(status: OSStatus, operation: Operation) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        switch operation {
        case .read: return "Couldn't read from the Keychain (\(detail))."
        case .save: return "Couldn't save to the Keychain (\(detail))."
        case .delete: return "Couldn't delete from the Keychain (\(detail))."
        }
    }
}
