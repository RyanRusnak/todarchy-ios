import XCTest
import CryptoKit
@testable import todarchy

final class InMemoryKeyStoreTests: XCTestCase {
    func testSaveThenLoadRoundTrips() throws {
        let store = InMemoryKeyStore()
        let key = CryptoBox.generateKey()
        try store.save(key, for: "p_abc")

        let loaded = store.load(for: "p_abc")
        XCTAssertNotNil(loaded)
        // Compare by sealed-bytes: same key ⇒ decrypt round-trips.
        let sealed = try CryptoBox.seal(Data("hello".utf8), with: key)
        XCTAssertEqual(try CryptoBox.open(sealed, with: loaded!), Data("hello".utf8))
    }

    func testLoadReturnsNilForUnknownProject() {
        let store = InMemoryKeyStore()
        XCTAssertNil(store.load(for: "nope"))
    }

    func testSaveOverwrites() throws {
        let store = InMemoryKeyStore()
        let k1 = CryptoBox.generateKey()
        let k2 = CryptoBox.generateKey()
        try store.save(k1, for: "p_x")
        try store.save(k2, for: "p_x")

        // The second save should have replaced the first — seal with
        // k2 and verify the loaded key opens it.
        let sealed = try CryptoBox.seal(Data("latest".utf8), with: k2)
        let loaded = store.load(for: "p_x")!
        XCTAssertEqual(try CryptoBox.open(sealed, with: loaded), Data("latest".utf8))
    }

    func testDeleteRemoves() throws {
        let store = InMemoryKeyStore()
        try store.save(CryptoBox.generateKey(), for: "p_x")
        XCTAssertNotNil(store.load(for: "p_x"))
        store.delete(for: "p_x")
        XCTAssertNil(store.load(for: "p_x"))
    }

    func testIsolatedByProjectId() throws {
        let store = InMemoryKeyStore()
        let a = CryptoBox.generateKey()
        let b = CryptoBox.generateKey()
        try store.save(a, for: "project_a")
        try store.save(b, for: "project_b")

        // Deleting one shouldn't touch the other.
        store.delete(for: "project_a")
        XCTAssertNil(store.load(for: "project_a"))
        XCTAssertNotNil(store.load(for: "project_b"))
    }
}

/// KeychainKeyStore tests hit the real keychain. They're gated by an
/// environment variable so CI / sandboxed test runs don't fail on
/// missing entitlements. Set `TODARCHY_RUN_KEYCHAIN_TESTS=1` locally
/// to exercise them.
final class KeychainKeyStoreTests: XCTestCase {
    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["TODARCHY_RUN_KEYCHAIN_TESTS"] == "1"
    }

    // Use a test-specific service name so we don't pollute the app's
    // real keychain entries during development.
    private let service = "com.todarchy.app.shared-keys.test"

    func testKeychainRoundTrip() throws {
        guard shouldRun else {
            throw XCTSkip("set TODARCHY_RUN_KEYCHAIN_TESTS=1 to exercise the real keychain path")
        }
        // Synchronizable=false avoids leaving stray entries in iCloud
        // Keychain across all of the developer's devices.
        let store = KeychainKeyStore(service: service, synchronizable: false)
        let id = "test_\(UUID().uuidString)"
        defer { store.delete(for: id) }

        let key = CryptoBox.generateKey()
        try store.save(key, for: id)

        let loaded = store.load(for: id)
        XCTAssertNotNil(loaded)
        let sealed = try CryptoBox.seal(Data("kc".utf8), with: key)
        XCTAssertEqual(try CryptoBox.open(sealed, with: loaded!), Data("kc".utf8))

        store.delete(for: id)
        XCTAssertNil(store.load(for: id))
    }
}
