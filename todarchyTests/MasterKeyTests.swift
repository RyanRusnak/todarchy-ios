import XCTest
import CryptoKit
import Argon2
@testable import todarchy

@MainActor
final class MasterKeyTests: XCTestCase {

    /// Tiny Argon2 params so the suite stays fast — derivation logic
    /// is what we're testing, not Argon2 throughput.
    private let fastParams = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
    private let testSalt = Data(repeating: 0x02, count: 16)
    private let altSalt  = Data(repeating: 0x03, count: 16)

    // MARK: - Initial state

    func testEmptyCacheMeansLocked() {
        let mk = MasterKey(cache: InMemoryMasterKeyCache())
        XCTAssertNil(mk.currentKey)
    }

    // MARK: - Derive

    func testDeriveSetsCurrentKey() async throws {
        let mk = MasterKey(cache: InMemoryMasterKeyCache())
        try await mk.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        XCTAssertNotNil(mk.currentKey)
    }

    func testDeriveIsDeterministic() async throws {
        let mkA = MasterKey(cache: InMemoryMasterKeyCache())
        let mkB = MasterKey(cache: InMemoryMasterKeyCache())
        try await mkA.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        try await mkB.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        XCTAssertEqual(mkA.currentKey?.withUnsafeBytes { Data($0) },
                       mkB.currentKey?.withUnsafeBytes { Data($0) })
    }

    /// Different passphrases derive different keys — sanity check that
    /// we're really calling Argon2 and not, e.g., returning the salt.
    func testDifferentPassphrasesDifferentKeys() async throws {
        let mkA = MasterKey(cache: InMemoryMasterKeyCache())
        let mkB = MasterKey(cache: InMemoryMasterKeyCache())
        try await mkA.derive(passphrase: "pw-a", salt: testSalt, params: fastParams)
        try await mkB.derive(passphrase: "pw-b", salt: testSalt, params: fastParams)
        XCTAssertNotEqual(mkA.currentKey?.withUnsafeBytes { Data($0) },
                          mkB.currentKey?.withUnsafeBytes { Data($0) })
    }

    // MARK: - Cache persistence

    /// A fresh `MasterKey` constructed on top of the same cache picks
    /// up the previously-derived key — this is the property that
    /// avoids re-prompting the user on every app launch.
    func testCachedKeyLoadsOnRebuild() async throws {
        let cache = InMemoryMasterKeyCache()
        let first = MasterKey(cache: cache)
        try await first.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        let originalKeyBytes = first.currentKey?.withUnsafeBytes { Data($0) }

        let second = MasterKey(cache: cache)
        XCTAssertEqual(second.currentKey?.withUnsafeBytes { Data($0) }, originalKeyBytes)
    }

    // MARK: - adoptSalt

    /// adoptSalt with the salt the cached key was derived from is a
    /// no-op for currentKey.
    func testAdoptMatchingSaltKeepsKey() async throws {
        let mk = MasterKey(cache: InMemoryMasterKeyCache())
        try await mk.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        let before = mk.currentKey?.withUnsafeBytes { Data($0) }
        mk.adoptSalt(testSalt)
        let after = mk.currentKey?.withUnsafeBytes { Data($0) }
        XCTAssertEqual(before, after)
    }

    /// adoptSalt with a different salt → cache is stale, drop it.
    func testAdoptMismatchedSaltClearsKeyAndCache() async throws {
        let cache = InMemoryMasterKeyCache()
        let mk = MasterKey(cache: cache)
        try await mk.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        XCTAssertNotNil(mk.currentKey)

        mk.adoptSalt(altSalt)
        XCTAssertNil(mk.currentKey)
        XCTAssertNil(cache.load(), "stale cache should have been cleared")
    }

    /// adoptSalt with empty cache leaves currentKey nil (no false
    /// "unlocked" state).
    func testAdoptOnEmptyCacheStaysLocked() {
        let mk = MasterKey(cache: InMemoryMasterKeyCache())
        mk.adoptSalt(testSalt)
        XCTAssertNil(mk.currentKey)
    }

    // MARK: - Forget

    func testForgetClearsKeyAndCache() async throws {
        let cache = InMemoryMasterKeyCache()
        let mk = MasterKey(cache: cache)
        try await mk.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        XCTAssertNotNil(mk.currentKey)
        XCTAssertNotNil(cache.load())

        mk.forget()
        XCTAssertNil(mk.currentKey)
        XCTAssertNil(cache.load())
    }

    // MARK: - setDerivedKey

    /// setDerivedKey writes both the current key and the cache, so a
    /// fresh MasterKey instance over the same cache picks it up.
    func testSetDerivedKeyWritesCurrentKeyAndCache() throws {
        let cache = InMemoryMasterKeyCache()
        let mk = MasterKey(cache: cache)
        let rawKey = Data(repeating: 0xAB, count: 32)
        try mk.setDerivedKey(rawKey, salt: testSalt)
        XCTAssertEqual(mk.currentKey?.withUnsafeBytes { Data($0) }, rawKey)

        // Cache load → second instance has the same key.
        let mk2 = MasterKey(cache: cache)
        XCTAssertEqual(mk2.currentKey?.withUnsafeBytes { Data($0) }, rawKey)
    }

    /// setDerivedKey must crash on a wrong-size key — it's the
    /// rotation flow's tight contract that we always pass 32 bytes.
    /// (Tested via precondition; XCTExpectFailure here would require
    /// a fatal-error catcher we don't have. Skipped on the assumption
    /// that the precondition lines are obvious.)

    // MARK: - Cross-check with Argon2

    /// The MasterKey-produced key must equal the raw Argon2 output for
    /// the same inputs. If this diverges (e.g. we accidentally swap
    /// salt and key in pack/unpack), it'd be a silent bug.
    func testMatchesRawArgon2Output() async throws {
        let mk = MasterKey(cache: InMemoryMasterKeyCache())
        try await mk.derive(passphrase: "pw", salt: testSalt, params: fastParams)
        let mkBytes = mk.currentKey?.withUnsafeBytes { Data($0) }
        let rawBytes = try Argon2.deriveKey(passphrase: "pw", salt: testSalt, params: fastParams)
        XCTAssertEqual(mkBytes, rawBytes)
    }
}
