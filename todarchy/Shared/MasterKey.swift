import Foundation
import CryptoKit
import Argon2

/// The per-user passphrase-derived master key, used to seal and open
/// the `shareKeys` map inside the main Automerge doc.
///
/// ## Lifecycle
///
///     ┌────────────┐  derive(pw, salt) ┌─────────────┐
///     │   nil      │ ─────────────────▶│ currentKey  │
///     │ (locked)   │ ◀──── forget() ───│ (unlocked)  │
///     └────────────┘                   └─────────────┘
///         ▲   ▲                              │
///         │   │                              ▼
///         │   └── adoptSalt(mismatched) ─────┘
///         │
///         └── app launch, no cache
///
/// `derive(passphrase:salt:)` runs Argon2 off the main actor (it's slow
/// on purpose — ~200–400 ms on M-series). On success, the 32-byte key
/// and the salt-it-came-from are written to a local, non-synchronizable
/// keychain entry so subsequent launches don't re-derive.
///
/// `adoptSalt(_:)` is called by `Persistence` after a main-doc sync.
/// It validates the cached key against the current doc salt — if the
/// user changed their passphrase on another device (new salt), the
/// cache is dropped and `currentKey` goes back to nil so the UI
/// prompts for the new passphrase.
@MainActor
final class MasterKey: ObservableObject {
    static let shared = MasterKey(cache: KeychainMasterKeyCache())

    @Published private(set) var currentKey: SymmetricKey?

    private let cache: MasterKeyCache

    init(cache: MasterKeyCache) {
        self.cache = cache
        // Optimistic load: if there's a cached blob, expose it as
        // `currentKey` immediately. The next `adoptSalt(_:)` call will
        // invalidate it if the salt no longer matches.
        if let blob = cache.load(), let unpacked = Self.unpack(blob) {
            self.currentKey = unpacked.key
        }
    }

    enum MasterKeyError: Error, LocalizedError, Equatable {
        case cacheWriteFailed(OSStatus)
        case cacheClearFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cacheWriteFailed(let s): return "Master-key cache write failed (\(s))"
            case .cacheClearFailed(let s): return "Master-key cache clear failed (\(s))"
            }
        }
    }

    /// Derive a master key from `passphrase` + `salt`, cache it, set
    /// `currentKey`. Argon2 is slow by design; this hops off the
    /// MainActor so the UI can show a spinner without freezing.
    func derive(passphrase: String,
                salt: Data,
                params: Argon2.Params = .interactive) async throws {
        let rawKey = try await Task.detached(priority: .userInitiated) {
            try Argon2.deriveKey(passphrase: passphrase, salt: salt, params: params)
        }.value
        try cache.save(Self.pack(key: rawKey, salt: salt))
        self.currentKey = SymmetricKey(data: rawKey)
    }

    /// Reconcile a cached key with the salt the main doc currently
    /// advertises. Match → keep `currentKey`. Mismatch (or no cache)
    /// → clear so the UI knows to prompt.
    func adoptSalt(_ salt: Data) {
        guard let blob = cache.load(), let unpacked = Self.unpack(blob) else {
            currentKey = nil
            return
        }
        if unpacked.salt == salt {
            currentKey = unpacked.key
        } else {
            try? cache.clear()
            currentKey = nil
        }
    }

    /// Drop the cached master key. Used for "Reset shared lists" and
    /// for explicit "Forget passphrase on this device" — doesn't
    /// touch the salt or `shareKeys` in the main doc.
    func forget() {
        try? cache.clear()
        currentKey = nil
    }

    /// Replace the cached master key directly, without re-running
    /// Argon2. Used by the rotation flow: the caller already
    /// derived a fresh key from the new passphrase + new salt and
    /// re-encrypted the cipher, so we don't want to pay another
    /// ~300 ms derivation just to write the cache.
    func setDerivedKey(_ rawKey: Data, salt: Data) throws {
        try cache.save(Self.pack(key: rawKey, salt: salt))
        self.currentKey = SymmetricKey(data: rawKey)
    }

    // MARK: - Blob layout

    /// Cache blob is `salt (16) ‖ rawKey (32)` = 48 bytes. Salt is
    /// stored alongside the key so we can detect "passphrase changed
    /// on another device" without an extra keychain entry.
    private static func pack(key: Data, salt: Data) -> Data {
        precondition(salt.count == 16, "salt must be 16 bytes")
        precondition(key.count == 32, "rawKey must be 32 bytes")
        return salt + key
    }

    private static func unpack(_ blob: Data) -> (key: SymmetricKey, salt: Data)? {
        guard blob.count == 48 else { return nil }
        let salt = Data(blob.prefix(16))
        let keyBytes = blob.suffix(32)
        return (SymmetricKey(data: keyBytes), salt)
    }
}

// MARK: - Cache abstraction

/// Storage for the cached `(salt, key)` blob. Concrete: keychain in
/// prod, in-memory in tests. The protocol mirrors `KeyStore` so the
/// app's storage layer stays uniform.
protocol MasterKeyCache {
    func load() -> Data?
    func save(_ blob: Data) throws
    func clear() throws
}

/// Production cache. Local-only — explicitly NOT synchronizable, so
/// the master key never travels via iCloud Keychain. Each device
/// re-derives from passphrase on first use; that's the design.
final class KeychainMasterKeyCache: MasterKeyCache {
    private let service: String
    private let account: String

    init(service: String = "com.todarchy.app.master-key",
         account: String = "user") {
        self.service = service
        self.account = account
    }

    func load() -> Data? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func save(_ blob: Data) throws {
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: blob] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = blob
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MasterKey.MasterKeyError.cacheWriteFailed(addStatus)
            }
            return
        }
        throw MasterKey.MasterKeyError.cacheWriteFailed(updateStatus)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MasterKey.MasterKeyError.cacheClearFailed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory cache for tests. Thread-safe via a plain mutex.
final class InMemoryMasterKeyCache: MasterKeyCache {
    private var blob: Data?
    private let lock = NSLock()

    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return blob
    }

    func save(_ blob: Data) throws {
        lock.lock(); defer { lock.unlock() }
        self.blob = blob
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        self.blob = nil
    }
}
