import XCTest
import Automerge
@testable import todarchy

/// Tests for the `shareKeys` top-level field in the main Automerge
/// doc — the wrapper that holds `version`, `salt`, and the sealed
/// `cipher` blob. The contents of `cipher` are exercised separately
/// in `ShareKeysMapTests`.
final class AutomergeStoreShareKeysTests: XCTestCase {

    private let salt = Data(repeating: 0x02, count: 16)
    private let altSalt = Data(repeating: 0x03, count: 16)
    private let cipher = Data(repeating: 0xAB, count: 80)
    private let altCipher = Data(repeating: 0xCD, count: 80)

    // MARK: - Empty / uninitialised reads

    /// A fresh doc carries no `shareKeys` map — all three accessors
    /// return nil. This is the "user has never opened the passphrase
    /// flow" state.
    func testFreshDocHasNoShareKeys() throws {
        let store = AutomergeStore()
        XCTAssertNil(try store.readShareKeysVersion())
        XCTAssertNil(try store.readShareKeysSalt())
        XCTAssertNil(try store.readShareKeysCipher())
    }

    // MARK: - Write/read salt

    func testWriteSaltCreatesShareKeysMap() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        XCTAssertEqual(try store.readShareKeysSalt(), salt)
        XCTAssertEqual(try store.readShareKeysVersion(), 1)
        XCTAssertNil(try store.readShareKeysCipher(),
                     "salt set without cipher → cipher remains nil")
    }

    /// Calling writeShareKeysSalt with the same salt twice is a no-op
    /// after the first call — important because the passphrase-setup
    /// UI may invoke this on every attempt.
    func testWriteSameSaltIsIdempotent() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysSalt(salt)
        XCTAssertEqual(try store.readShareKeysSalt(), salt)
    }

    /// Replacing the salt (e.g. user does "Reset shared lists" then
    /// re-sets a passphrase) updates the stored value.
    func testWriteDifferentSaltReplaces() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysSalt(altSalt)
        XCTAssertEqual(try store.readShareKeysSalt(), altSalt)
    }

    // MARK: - Write/read cipher

    func testWriteCipherStoresBytes() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysCipher(cipher)
        XCTAssertEqual(try store.readShareKeysCipher(), cipher)
    }

    func testWriteCipherReplacesExisting() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysCipher(cipher)
        try store.writeShareKeysCipher(altCipher)
        XCTAssertEqual(try store.readShareKeysCipher(), altCipher)
        // Salt is unaffected by cipher writes.
        XCTAssertEqual(try store.readShareKeysSalt(), salt)
    }

    // MARK: - Clear

    func testClearRemovesEverything() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysCipher(cipher)
        try store.clearShareKeys()
        XCTAssertNil(try store.readShareKeysSalt())
        XCTAssertNil(try store.readShareKeysCipher())
        XCTAssertNil(try store.readShareKeysVersion())
    }

    func testClearOnUninitialisedDocIsNoOp() throws {
        let store = AutomergeStore()
        XCTAssertNoThrow(try store.clearShareKeys())
    }

    // MARK: - Round-trip through save/load

    /// Save the doc to bytes and reload — shareKeys fields must
    /// survive the round-trip. This is the property cross-device
    /// sync relies on.
    func testSurvivesSaveAndReload() throws {
        let store = AutomergeStore()
        try store.writeShareKeysSalt(salt)
        try store.writeShareKeysCipher(cipher)
        let bytes = store.save()

        let reloaded = AutomergeStore(data: bytes)
        XCTAssertEqual(try reloaded.readShareKeysSalt(), salt)
        XCTAssertEqual(try reloaded.readShareKeysCipher(), cipher)
        XCTAssertEqual(try reloaded.readShareKeysVersion(), 1)
    }

    // MARK: - Merge semantics

    /// Two devices set the same salt independently then merge —
    /// salt should remain a single value, not duplicate or split.
    /// This is the "I configured the passphrase on Mac, then opened
    /// the iPhone and synced" path.
    func testConcurrentSaltSetMergesCleanly() throws {
        let a = AutomergeStore()
        try a.writeShareKeysSalt(salt)

        let b = AutomergeStore(data: a.save())
        // Both write the same cipher — common case after first sync.
        try a.writeShareKeysCipher(cipher)
        try b.writeShareKeysCipher(cipher)

        try a.merge(b)
        XCTAssertEqual(try a.readShareKeysSalt(), salt)
        XCTAssertEqual(try a.readShareKeysCipher(), cipher)
    }
}
