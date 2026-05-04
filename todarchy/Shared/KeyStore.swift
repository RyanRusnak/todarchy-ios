import Foundation
import CryptoKit
import Security

/// Abstract storage for per-project symmetric keys. The real app uses
/// `KeychainKeyStore`; tests use `InMemoryKeyStore` to avoid hitting
/// the system keychain in CI.
protocol KeyStore {
    func save(_ key: SymmetricKey, for projectId: String) throws
    func load(for projectId: String) -> SymmetricKey?
    func delete(for projectId: String)
}

// MARK: - Keychain implementation

/// Stores per-project keys in the system keychain.
///
/// Defaults to **local-only** storage (not synchronizable). iCloud
/// Keychain sync is nice-to-have but requires the iCloud services
/// entitlement + a proper Developer ID signature — ad-hoc-signed dev
/// builds get `errSecMissingEntitlement` (-34018) if we set
/// `kSecAttrSynchronizable = true`. Share links already handle the
/// cross-device case: the user pastes the same link on each of their
/// devices just like a collaborator would.
///
/// Set `synchronizable: true` explicitly once the app ships with the
/// iCloud Keychain entitlement.
///
/// Service name is namespaced to the app's bundle id so two todarchy
/// installs (e.g. Debug + Release) don't collide.
final class KeychainKeyStore: KeyStore {
    enum KeychainError: Error, LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case dataInvalid

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): return "Keychain error (\(s))"
            case .dataInvalid: return "Stored key bytes were not a valid 256-bit key."
            }
        }
    }

    private let service: String
    /// If true, items are flagged for iCloud Keychain sync so they
    /// reach the user's other devices. Requires the iCloud Keychain
    /// entitlement — off by default so ad-hoc-signed builds work.
    private let synchronizable: Bool

    init(service: String = "com.todarchy.app.shared-keys",
         synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    func save(_ key: SymmetricKey, for projectId: String) throws {
        let raw = key.withUnsafeBytes { Data($0) }
        var query = baseQuery(for: projectId)

        // Try an update first — if the item exists, update in place.
        let attrsToUpdate: [String: Any] = [kSecValueData as String: raw]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrsToUpdate as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            // Fresh add.
            var add = query
            add[kSecValueData as String] = raw
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    func load(for projectId: String) -> SymmetricKey? {
        var query = baseQuery(for: projectId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func delete(for projectId: String) {
        let query = baseQuery(for: projectId)
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: -

    private func baseQuery(for projectId: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: projectId,
        ]
        if synchronizable {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return q
    }
}

// MARK: - In-memory (test) implementation

/// Thread-safe in-memory key store for tests. Keeps the same API
/// surface so production code paths can depend on `KeyStore` and get
/// either implementation via init injection.
final class InMemoryKeyStore: KeyStore {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func save(_ key: SymmetricKey, for projectId: String) throws {
        let raw = key.withUnsafeBytes { Data($0) }
        lock.lock(); defer { lock.unlock() }
        storage[projectId] = raw
    }

    func load(for projectId: String) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[projectId] else { return nil }
        return SymmetricKey(data: data)
    }

    func delete(for projectId: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: projectId)
    }
}
