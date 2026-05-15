import Foundation
import CryptoKit
import Argon2

/// Coordinator between four pieces of the share-keys propagation
/// machinery:
///
///   - `MasterKey`             — passphrase-derived AEAD key (live)
///   - `KeyStore`              — local keychain of per-project keys
///   - `AutomergeStore`        — `shareKeys.{salt,cipher}` on the doc
///   - `ShareKeysMap`          — JSON inside `cipher`, before sealing
///
/// Owns no state of its own (other than its dependencies). All
/// operations are idempotent: re-running them produces the same
/// result, so callers don't have to coordinate retries.
///
/// Threading: `@MainActor` because it touches `MasterKey`. The
/// `AutomergeStore` methods it calls have their own internal lock,
/// and `KeyStore` implementations are required to be thread-safe.
@MainActor
final class ShareKeysSync {
    static let shared = ShareKeysSync(
        masterKey: MasterKey.shared,
        keyStore: KeychainKeyStore()
    )

    let masterKey: MasterKey
    let keyStore: KeyStore

    init(masterKey: MasterKey, keyStore: KeyStore) {
        self.masterKey = masterKey
        self.keyStore = keyStore
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case locked
        case wrongPassphrase
        case saltGenerationFailed

        var errorDescription: String? {
            switch self {
            case .locked:
                return "Set up your sync passphrase before sharing a list."
            case .wrongPassphrase:
                return "That passphrase doesn't match the one used on your other devices."
            case .saltGenerationFailed:
                return "Couldn't generate a random salt — try again."
            }
        }
    }

    // MARK: - Passphrase setup

    /// Set up the passphrase on this device.
    ///
    /// Two paths:
    ///   1. **First device.** No salt on the doc yet → generate a
    ///      fresh 16-byte salt, write it to the doc, derive the
    ///      master key. The doc's `cipher` is left untouched (the
    ///      next share will populate it).
    ///   2. **Subsequent device.** Salt already exists on the doc
    ///      (set by another of the user's devices that synced first).
    ///      Use that salt to derive a master key from the passphrase,
    ///      then validate by opening any existing `cipher`. Wrong
    ///      passphrase → `.wrongPassphrase` is thrown and the cached
    ///      master key is forgotten.
    ///
    /// Idempotent in both directions: calling it twice with the
    /// correct passphrase is a no-op the second time.
    func setupPassphrase(_ passphrase: String, store: AutomergeStore) async throws {
        let salt: Data
        if let existing = try store.readShareKeysSalt() {
            salt = existing
        } else {
            guard let fresh = Self.randomSalt() else {
                throw Error.saltGenerationFailed
            }
            salt = fresh
            try store.writeShareKeysSalt(salt)
        }

        try await masterKey.derive(passphrase: passphrase, salt: salt)

        // If a cipher already exists, prove the derived master key
        // opens it. This is what makes "wrong passphrase on a second
        // device" a clean rejection instead of a silent split-brain.
        if let cipher = try store.readShareKeysCipher() {
            guard let masterK = masterKey.currentKey else {
                throw Error.locked   // shouldn't happen — derive just set it
            }
            do {
                let map = try ShareKeysMap.open(cipher, with: masterK)
                // Side effect: import any keys we don't already have
                // locally so the user sees their shared lists right
                // after passphrase entry, without waiting for the
                // next adoptFromDoc tick.
                importKeys(from: map)
            } catch {
                masterKey.forget()
                throw Error.wrongPassphrase
            }
        }
    }

    // MARK: - Rotate passphrase

    /// Change the user's passphrase. Requires the current master key
    /// to be unlocked (otherwise it's a "set passphrase" flow, not a
    /// rotation). Generates a fresh salt, derives the new master key
    /// from `newPassphrase + newSalt`, re-encrypts the existing
    /// `shareKeys.cipher` under the new key, and atomically writes
    /// both the new salt and the re-encrypted cipher to the doc.
    ///
    /// Side effect: the user's other devices will detect a salt
    /// change on their next sync, drop their cached master key, and
    /// prompt for the new passphrase.
    func rotatePassphrase(_ newPassphrase: String,
                          store: AutomergeStore,
                          params: Argon2.Params = .interactive) async throws {
        guard let currentMasterKey = masterKey.currentKey else {
            throw Error.locked
        }
        // Read + decrypt with the current master key BEFORE we write
        // anything — if the decrypt fails partway, the doc is left
        // unchanged.
        let map = (try Self.openMap(in: store, with: currentMasterKey)) ?? .empty

        guard let newSalt = Self.randomSalt() else {
            throw Error.saltGenerationFailed
        }

        // Derive the new key off the MainActor — Argon2 is slow.
        let newRawKey = try await Task.detached(priority: .userInitiated) {
            try Argon2.deriveKey(passphrase: newPassphrase, salt: newSalt, params: params)
        }.value
        let newMasterKey = SymmetricKey(data: newRawKey)

        // Write new salt and re-sealed cipher.
        try store.writeShareKeysSalt(newSalt)
        try store.writeShareKeysCipher(map.seal(with: newMasterKey))

        // Swap the cached master key on this device. Use setDerivedKey
        // to skip a redundant Argon2 round.
        try masterKey.setDerivedKey(newRawKey, salt: newSalt)
    }

    // MARK: - Publish / unpublish

    /// Add or replace a per-project key in the user's sealed
    /// `shareKeys` map. Called after `manager.createShared(...)` or
    /// `manager.accept(...)` so the key propagates to the user's
    /// other devices via main-doc sync.
    func publish(projectId: String,
                 key: SymmetricKey,
                 store: AutomergeStore) throws {
        guard let masterK = masterKey.currentKey else { throw Error.locked }
        try Self.publish(projectId: projectId, key: key, masterKey: masterK, store: store)
    }

    /// Remove a per-project key from the user's sealed map. Used
    /// when the user does "Leave shared project" — the encrypted
    /// envelope on the server stays untouched, only this user's
    /// reference to its key is dropped.
    func unpublish(projectId: String, store: AutomergeStore) throws {
        guard let masterK = masterKey.currentKey else { throw Error.locked }
        try Self.unpublish(projectId: projectId, masterKey: masterK, store: store)
    }

    // MARK: - Nonisolated pure ops
    //
    // Variants that take the master key value directly so the
    // persistence queue can call them without hopping to MainActor.
    // The instance methods above are thin convenience wrappers that
    // read `masterKey.currentKey` and delegate here.

    nonisolated static func publish(projectId: String,
                                    key: SymmetricKey,
                                    masterKey: SymmetricKey,
                                    store: AutomergeStore) throws {
        var map = (try Self.openMap(in: store, with: masterKey)) ?? .empty
        map.setKey(key, for: projectId)
        try store.writeShareKeysCipher(map.seal(with: masterKey))
    }

    nonisolated static func unpublish(projectId: String,
                                      masterKey: SymmetricKey,
                                      store: AutomergeStore) throws {
        guard var map = try Self.openMap(in: store, with: masterKey) else { return }
        guard map.keys[projectId] != nil else { return }
        map.remove(projectId: projectId)
        try store.writeShareKeysCipher(map.seal(with: masterKey))
    }

    /// Decrypt the `shareKeys.cipher` on `store` using `masterKey`.
    /// Returns nil if no cipher is stored yet. Throws on
    /// wrong-key / tamper / malformed JSON.
    nonisolated static func openMap(in store: AutomergeStore,
                                    with masterKey: SymmetricKey) throws -> ShareKeysMap? {
        guard let cipher = try store.readShareKeysCipher() else { return nil }
        return try ShareKeysMap.open(cipher, with: masterKey)
    }

    /// Migration helper: publish any keys already in the local keystore
    /// (e.g. from share links opened before the passphrase feature
    /// existed) into the user's main-doc cipher. Idempotent — keys
    /// already in the cipher are left alone. Returns the count
    /// newly published.
    ///
    /// Called once right after the first passphrase setup, with
    /// project ids drawn from `KeyStore.allProjectIds()`.
    @discardableResult
    nonisolated static func migrateLocalKeys(keyStore: KeyStore,
                                             masterKey: SymmetricKey,
                                             store: AutomergeStore) throws -> Int {
        let projectIds = keyStore.allProjectIds()
        guard !projectIds.isEmpty else { return 0 }
        var map = (try Self.openMap(in: store, with: masterKey)) ?? .empty
        var published = 0
        for pid in projectIds where map.keys[pid] == nil {
            guard let key = keyStore.load(for: pid) else { continue }
            map.setKey(key, for: pid)
            published += 1
        }
        if published > 0 {
            try store.writeShareKeysCipher(map.seal(with: masterKey))
        }
        return published
    }

    // MARK: - Adopt

    /// Called by `Persistence` after each main-doc merge. Walks the
    /// shareKeys map and imports any keys we don't already have in
    /// the local keychain. Returns the number of keys imported (for
    /// logging / diagnostics).
    ///
    /// No-ops cleanly when:
    ///   - The doc has no shareKeys yet (user hasn't set a passphrase).
    ///   - The doc has a salt but `MasterKey` is still locked (user
    ///     hasn't entered their passphrase on this device yet).
    ///   - The salt on the doc doesn't match the cached master key
    ///     (passphrase changed on another device) — MasterKey
    ///     invalidates its cache and we exit so the UI can prompt.
    @discardableResult
    func adoptFromDoc(_ store: AutomergeStore) throws -> Int {
        guard let salt = try store.readShareKeysSalt() else { return 0 }
        masterKey.adoptSalt(salt)

        guard let masterK = masterKey.currentKey else { return 0 }
        guard let map = try Self.openMap(in: store, with: masterK) else { return 0 }
        return importKeys(from: map)
    }

    // MARK: - Internals

    /// Save any keys from `map` that aren't already in the local
    /// keychain. Returns the count actually imported.
    @discardableResult
    private func importKeys(from map: ShareKeysMap) -> Int {
        var imported = 0
        for projectId in map.keys.keys {
            guard let key = map.key(for: projectId) else { continue }
            if keyStore.load(for: projectId) == nil {
                do {
                    try keyStore.save(key, for: projectId)
                    imported += 1
                } catch {
                    // Keychain write failure is rare and recoverable
                    // on the next adoptFromDoc tick. Don't break the
                    // sync flow over it.
                    #if DEBUG
                    print("todarchy: failed to import key for \(projectId): \(error)")
                    #endif
                }
            }
        }
        return imported
    }

    /// 16 cryptographically-random bytes from SecRandom. Returns nil
    /// only if the OS RNG fails, which is essentially never.
    private static func randomSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return Data(bytes)
    }
}
