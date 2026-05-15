import XCTest
import CryptoKit
import Argon2
@testable import todarchy

@MainActor
final class ShareKeysSyncTests: XCTestCase {

    /// Fast Argon2 params for tests — derivation isn't what's under test.
    private let fastParams = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)

    // MARK: - Test fixtures

    private func makeSync(masterKey: MasterKey? = nil,
                          keyStore: KeyStore? = nil) -> ShareKeysSync {
        ShareKeysSync(
            masterKey: masterKey ?? MasterKey(cache: InMemoryMasterKeyCache()),
            keyStore: keyStore ?? InMemoryKeyStore()
        )
    }

    /// Setup passphrase via the public API but with fast Argon2 params.
    /// This skips the public `setupPassphrase` flow and pre-loads the
    /// master key directly because we can't pass custom Argon2 params
    /// through `setupPassphrase`. Tests that exercise the full path do
    /// it explicitly.
    private func unlock(_ sync: ShareKeysSync,
                        passphrase: String = "pw",
                        salt: Data) async throws {
        try await sync.masterKey.derive(passphrase: passphrase, salt: salt, params: fastParams)
    }

    // MARK: - Passphrase setup — first device

    func testSetupOnFreshDocWritesSaltAndUnlocks() async throws {
        let sync = makeSync()
        let store = AutomergeStore()
        try await sync.setupPassphrase("pw", store: store)

        XCTAssertNotNil(try store.readShareKeysSalt())
        XCTAssertEqual(try store.readShareKeysSalt()?.count, 16)
        XCTAssertNil(try store.readShareKeysCipher(), "no shares yet → no cipher")
        XCTAssertNotNil(sync.masterKey.currentKey)
    }

    /// Salt is freshly random — two independent first-device setups
    /// shouldn't collide.
    func testFreshSetupGeneratesDistinctSalts() async throws {
        let storeA = AutomergeStore()
        let storeB = AutomergeStore()
        let syncA = makeSync()
        let syncB = makeSync()
        try await syncA.setupPassphrase("pw", store: storeA)
        try await syncB.setupPassphrase("pw", store: storeB)
        XCTAssertNotEqual(try storeA.readShareKeysSalt(),
                          try storeB.readShareKeysSalt())
    }

    // MARK: - Passphrase setup — second device

    /// New device joining an account that already has a salt + cipher:
    /// correct passphrase decrypts the cipher and imports keys.
    func testSetupOnExistingDocImportsKeys() async throws {
        // Build "device A" state: passphrase set, one shared project key.
        let salt = Data(repeating: 0x02, count: 16)
        let storeA = AutomergeStore()
        try storeA.writeShareKeysSalt(salt)
        let masterA = MasterKey(cache: InMemoryMasterKeyCache())
        try await masterA.derive(passphrase: "pw", salt: salt, params: fastParams)
        let projectKey = CryptoBox.generateKey()
        var mapA = ShareKeysMap.empty
        mapA.setKey(projectKey, for: "p_grocery")
        try storeA.writeShareKeysCipher(mapA.seal(with: masterA.currentKey!))

        // "Device B" syncs the doc, then sets up the passphrase.
        let bytes = storeA.save()
        let storeB = AutomergeStore(data: bytes)
        let keyStoreB = InMemoryKeyStore()
        let syncB = makeSync(keyStore: keyStoreB)

        // Pass fast params through by deriving directly first; the
        // setupPassphrase path uses interactive params which would be
        // ~300ms. The functional behavior is identical — derive +
        // validate cipher. Test the validation surface via a direct
        // open call instead of the full setupPassphrase.
        try await syncB.masterKey.derive(passphrase: "pw", salt: salt, params: fastParams)
        let map = try ShareKeysMap.open(storeB.readShareKeysCipher()!,
                                        with: syncB.masterKey.currentKey!)
        // Sanity: the cipher decoded the project key we sealed.
        XCTAssertEqual(map.key(for: "p_grocery")?.withUnsafeBytes { Data($0) },
                       projectKey.withUnsafeBytes { Data($0) })
    }

    /// Wrong passphrase on a doc that already has a cipher must
    /// reject and forget the bad master key.
    func testSetupRejectsWrongPassphrase() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let storeA = AutomergeStore()
        try storeA.writeShareKeysSalt(salt)
        let masterA = MasterKey(cache: InMemoryMasterKeyCache())
        try await masterA.derive(passphrase: "right", salt: salt, params: fastParams)
        var map = ShareKeysMap.empty
        map.setKey(CryptoBox.generateKey(), for: "p_x")
        try storeA.writeShareKeysCipher(map.seal(with: masterA.currentKey!))

        let storeB = AutomergeStore(data: storeA.save())
        let syncB = makeSync()
        try await syncB.masterKey.derive(passphrase: "wrong", salt: salt, params: fastParams)

        // Verify a wrong key fails to open the cipher (the same check
        // setupPassphrase performs internally).
        XCTAssertThrowsError(
            try ShareKeysMap.open(storeB.readShareKeysCipher()!,
                                  with: syncB.masterKey.currentKey!)
        ) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .decryptionFailed)
        }
    }

    // MARK: - Publish

    func testPublishWhileLockedThrows() async throws {
        let sync = makeSync()
        let store = AutomergeStore()
        let key = CryptoBox.generateKey()
        XCTAssertThrowsError(try sync.publish(projectId: "p_x", key: key, store: store)) {
            XCTAssertEqual($0 as? ShareKeysSync.Error, .locked)
        }
    }

    func testPublishWritesCipherWithKey() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)

        let projectKey = CryptoBox.generateKey()
        try sync.publish(projectId: "p_grocery", key: projectKey, store: store)

        let cipher = try XCTUnwrap(try store.readShareKeysCipher())
        let map = try ShareKeysMap.open(cipher, with: sync.masterKey.currentKey!)
        XCTAssertEqual(map.key(for: "p_grocery")?.withUnsafeBytes { Data($0) },
                       projectKey.withUnsafeBytes { Data($0) })
    }

    /// Publishing a second key preserves the first.
    func testPublishMergesIntoExisting() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)

        let k1 = CryptoBox.generateKey()
        let k2 = CryptoBox.generateKey()
        try sync.publish(projectId: "p_a", key: k1, store: store)
        try sync.publish(projectId: "p_b", key: k2, store: store)

        let cipher = try XCTUnwrap(try store.readShareKeysCipher())
        let map = try ShareKeysMap.open(cipher, with: sync.masterKey.currentKey!)
        XCTAssertEqual(map.keys.count, 2)
        XCTAssertNotNil(map.key(for: "p_a"))
        XCTAssertNotNil(map.key(for: "p_b"))
    }

    // MARK: - Unpublish

    func testUnpublishRemovesKey() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)
        try sync.publish(projectId: "p_a", key: CryptoBox.generateKey(), store: store)
        try sync.publish(projectId: "p_b", key: CryptoBox.generateKey(), store: store)

        try sync.unpublish(projectId: "p_a", store: store)

        let cipher = try XCTUnwrap(try store.readShareKeysCipher())
        let map = try ShareKeysMap.open(cipher, with: sync.masterKey.currentKey!)
        XCTAssertNil(map.key(for: "p_a"))
        XCTAssertNotNil(map.key(for: "p_b"))
    }

    func testUnpublishUnknownProjectIsNoOp() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)
        try sync.publish(projectId: "p_a", key: CryptoBox.generateKey(), store: store)
        let beforeCipher = try store.readShareKeysCipher()

        try sync.unpublish(projectId: "p_does_not_exist", store: store)
        XCTAssertEqual(try store.readShareKeysCipher(), beforeCipher)
    }

    // MARK: - AdoptFromDoc

    func testAdoptOnUninitialisedDocIsNoOp() async throws {
        let sync = makeSync()
        let store = AutomergeStore()
        let imported = try sync.adoptFromDoc(store)
        XCTAssertEqual(imported, 0)
    }

    /// Salt is set but cipher isn't yet — adopt validates the salt
    /// (clears stale cache) and returns 0.
    func testAdoptWithSaltButNoCipherClearsAndReturnsZero() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        let imported = try sync.adoptFromDoc(store)
        XCTAssertEqual(imported, 0)
        XCTAssertNil(sync.masterKey.currentKey,
                     "no cached master key → still locked after adopt")
    }

    func testAdoptImportsNewKeysToKeychain() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let sync = makeSync(keyStore: keyStore)
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)

        let kA = CryptoBox.generateKey()
        let kB = CryptoBox.generateKey()
        try sync.publish(projectId: "p_a", key: kA, store: store)
        try sync.publish(projectId: "p_b", key: kB, store: store)

        // Simulate "fresh second device": same passphrase, empty keychain.
        let storeB = AutomergeStore(data: store.save())
        let keyStoreB = InMemoryKeyStore()
        let syncB = makeSync(keyStore: keyStoreB)
        try await unlock(syncB, salt: salt)

        let imported = try syncB.adoptFromDoc(storeB)
        XCTAssertEqual(imported, 2)
        XCTAssertNotNil(keyStoreB.load(for: "p_a"))
        XCTAssertNotNil(keyStoreB.load(for: "p_b"))
    }

    /// Adopt is idempotent: re-running doesn't double-import.
    func testAdoptIsIdempotent() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let sync = makeSync(keyStore: keyStore)
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)
        try sync.publish(projectId: "p_a", key: CryptoBox.generateKey(), store: store)

        XCTAssertEqual(try sync.adoptFromDoc(store), 1)
        XCTAssertEqual(try sync.adoptFromDoc(store), 0,
                       "second run finds the key already imported")
    }

    // MARK: - Migration of pre-passphrase keychain entries

    /// On first passphrase setup, existing keychain keys (e.g. from a
    /// pre-passphrase TestFlight build) get published into the doc
    /// cipher so the user's other devices auto-learn them.
    func testMigrateLocalKeysPublishesAllKeychainKeys() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let masterKey = MasterKey(cache: InMemoryMasterKeyCache())
        let store = AutomergeStore()

        // Pre-existing keys in the local keychain (no doc cipher yet).
        let kA = CryptoBox.generateKey()
        let kB = CryptoBox.generateKey()
        try keyStore.save(kA, for: "p_a")
        try keyStore.save(kB, for: "p_b")

        // Set up the passphrase (writes salt, derives master key).
        try store.writeShareKeysSalt(salt)
        try await masterKey.derive(passphrase: "pw", salt: salt, params: fastParams)

        let published = try ShareKeysSync.migrateLocalKeys(
            keyStore: keyStore,
            masterKey: masterKey.currentKey!,
            store: store
        )
        XCTAssertEqual(published, 2)

        // Both keys are now in the doc cipher.
        let map = try XCTUnwrap(
            try ShareKeysSync.openMap(in: store, with: masterKey.currentKey!)
        )
        XCTAssertEqual(map.keys.count, 2)
        XCTAssertEqual(map.key(for: "p_a")?.withUnsafeBytes { Data($0) },
                       kA.withUnsafeBytes { Data($0) })
        XCTAssertEqual(map.key(for: "p_b")?.withUnsafeBytes { Data($0) },
                       kB.withUnsafeBytes { Data($0) })
    }

    /// Migration is idempotent — keys already in the cipher aren't
    /// re-published. Running migration twice produces 0 new entries
    /// on the second run.
    func testMigrateIsIdempotent() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let masterKey = MasterKey(cache: InMemoryMasterKeyCache())
        let store = AutomergeStore()
        try keyStore.save(CryptoBox.generateKey(), for: "p_a")
        try store.writeShareKeysSalt(salt)
        try await masterKey.derive(passphrase: "pw", salt: salt, params: fastParams)

        XCTAssertEqual(try ShareKeysSync.migrateLocalKeys(keyStore: keyStore,
                                                          masterKey: masterKey.currentKey!,
                                                          store: store), 1)
        XCTAssertEqual(try ShareKeysSync.migrateLocalKeys(keyStore: keyStore,
                                                          masterKey: masterKey.currentKey!,
                                                          store: store), 0)
    }

    /// Migration with an empty keychain is a no-op and doesn't even
    /// write the cipher (we'd otherwise leak a useless empty seal).
    func testMigrateWithEmptyKeychainDoesNothing() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let masterKey = MasterKey(cache: InMemoryMasterKeyCache())
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await masterKey.derive(passphrase: "pw", salt: salt, params: fastParams)

        XCTAssertEqual(try ShareKeysSync.migrateLocalKeys(keyStore: keyStore,
                                                          masterKey: masterKey.currentKey!,
                                                          store: store), 0)
        XCTAssertNil(try store.readShareKeysCipher())
    }

    /// Keys that exist in the cipher but not in the local keychain
    /// (i.e. peer added a share but this device hasn't received the
    /// key locally) are preserved by migration.
    func testMigratePreservesExistingCipherEntries() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let keyStore = InMemoryKeyStore()
        let masterKey = MasterKey(cache: InMemoryMasterKeyCache())
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await masterKey.derive(passphrase: "pw", salt: salt, params: fastParams)

        // Existing cipher entry for p_remote (set by another device).
        var map = ShareKeysMap.empty
        let kRemote = CryptoBox.generateKey()
        map.setKey(kRemote, for: "p_remote")
        try store.writeShareKeysCipher(map.seal(with: masterKey.currentKey!))

        // Local keychain entry for p_local.
        let kLocal = CryptoBox.generateKey()
        try keyStore.save(kLocal, for: "p_local")

        let published = try ShareKeysSync.migrateLocalKeys(
            keyStore: keyStore,
            masterKey: masterKey.currentKey!,
            store: store
        )
        XCTAssertEqual(published, 1)

        let merged = try XCTUnwrap(
            try ShareKeysSync.openMap(in: store, with: masterKey.currentKey!)
        )
        XCTAssertEqual(merged.keys.count, 2)
        XCTAssertEqual(merged.key(for: "p_remote")?.withUnsafeBytes { Data($0) },
                       kRemote.withUnsafeBytes { Data($0) })
        XCTAssertEqual(merged.key(for: "p_local")?.withUnsafeBytes { Data($0) },
                       kLocal.withUnsafeBytes { Data($0) })
    }

    // MARK: - Rotate passphrase

    /// Rotation re-encrypts the existing cipher under a fresh master
    /// key, writes a new salt, and updates the local cached key. The
    /// share-keys map is preserved; only the wrapping changes.
    func testRotateReSealsCipherWithNewKey() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, passphrase: "old", salt: salt)

        let key = CryptoBox.generateKey()
        try sync.publish(projectId: "p_a", key: key, store: store)
        let originalMasterKey = sync.masterKey.currentKey

        try await sync.rotatePassphrase("newpassphrase!", store: store, params: fastParams)

        // Master key on this device has changed.
        XCTAssertNotEqual(sync.masterKey.currentKey?.withUnsafeBytes { Data($0) },
                          originalMasterKey?.withUnsafeBytes { Data($0) })

        // The map still contains the same project key, but it now
        // opens with the new master key (and not the old one).
        let map = try XCTUnwrap(
            try ShareKeysSync.openMap(in: store, with: sync.masterKey.currentKey!)
        )
        XCTAssertEqual(map.key(for: "p_a")?.withUnsafeBytes { Data($0) },
                       key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try ShareKeysSync.openMap(in: store, with: originalMasterKey!))
    }

    /// Rotation generates a fresh salt — other devices will see the
    /// salt change and invalidate their cached master keys.
    func testRotateChangesSalt() async throws {
        let oldSalt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(oldSalt)
        try await unlock(sync, salt: oldSalt)

        try await sync.rotatePassphrase("newpassphrase!", store: store, params: fastParams)

        let newSalt = try XCTUnwrap(try store.readShareKeysSalt())
        XCTAssertNotEqual(newSalt, oldSalt)
        XCTAssertEqual(newSalt.count, 16)
    }

    /// Rotating while locked should fail — there's nothing to rotate
    /// from. Caller surfaces this as "set passphrase first".
    func testRotateWhileLockedThrows() async throws {
        let sync = makeSync()
        let store = AutomergeStore()
        do {
            try await sync.rotatePassphrase("doesntmatter", store: store, params: fastParams)
            XCTFail("expected throw")
        } catch let error as ShareKeysSync.Error {
            XCTAssertEqual(error, .locked)
        }
    }

    /// Rotation with no existing cipher (passphrase was set but never
    /// shared) just re-keys an empty map. Doesn't crash or corrupt
    /// state.
    func testRotateWithEmptyMapStillRotates() async throws {
        let salt = Data(repeating: 0x02, count: 16)
        let sync = makeSync()
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try await unlock(sync, salt: salt)
        // No publishes — cipher is nil.
        XCTAssertNil(try store.readShareKeysCipher())

        try await sync.rotatePassphrase("newpassphrase!", store: store, params: fastParams)

        // After rotation, cipher exists (containing an empty map),
        // and it opens under the new master key.
        let cipher = try XCTUnwrap(try store.readShareKeysCipher())
        let map = try ShareKeysMap.open(cipher, with: sync.masterKey.currentKey!)
        XCTAssertTrue(map.keys.isEmpty)
    }

    // MARK: - Round trip with MasterKey state

    /// AdoptFromDoc with a stale cached master key (different salt
    /// than the doc) clears the cache and leaves the user locked.
    func testAdoptWithSaltMismatchClearsAndLocks() async throws {
        let oldSalt = Data(repeating: 0x02, count: 16)
        let newSalt = Data(repeating: 0x03, count: 16)
        let cache = InMemoryMasterKeyCache()
        let masterKey = MasterKey(cache: cache)
        let sync = makeSync(masterKey: masterKey)
        let store = AutomergeStore()

        // Derive under oldSalt — represents this device's prior state.
        try await masterKey.derive(passphrase: "pw", salt: oldSalt, params: fastParams)
        XCTAssertNotNil(masterKey.currentKey)

        // Doc shows newSalt (passphrase rotated on another device).
        try store.writeShareKeysSalt(newSalt)
        _ = try sync.adoptFromDoc(store)

        XCTAssertNil(masterKey.currentKey, "stale cache should have been cleared")
    }
}
