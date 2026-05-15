import XCTest
@testable import Argon2

final class Argon2Tests: XCTestCase {
    /// Smoke test: derivation runs and produces 32 bytes for typical
    /// inputs. Uses tiny parameters so the test is fast.
    func testDerivesKeyOfRequestedLength() throws {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let salt = Data(repeating: 0x02, count: 16)
        let key = try Argon2.deriveKey(passphrase: "correct horse battery staple",
                                       salt: salt,
                                       params: params,
                                       keyLength: 32)
        XCTAssertEqual(key.count, 32)
    }

    /// Determinism: same inputs → same output. This is the property
    /// that the cross-device sync flow relies on (Mac and iPhone
    /// derive the same master key from the same passphrase + salt).
    func testIsDeterministic() throws {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let salt = Data(repeating: 0x02, count: 16)
        let a = try Argon2.deriveKey(passphrase: "pw", salt: salt, params: params)
        let b = try Argon2.deriveKey(passphrase: "pw", salt: salt, params: params)
        XCTAssertEqual(a, b)
    }

    /// Different passphrases must produce different keys, even with
    /// the same salt + params. Sanity check that we're not silently
    /// returning a constant.
    func testDiffersByPassphrase() throws {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let salt = Data(repeating: 0x02, count: 16)
        let a = try Argon2.deriveKey(passphrase: "passphrase-a", salt: salt, params: params)
        let b = try Argon2.deriveKey(passphrase: "passphrase-b", salt: salt, params: params)
        XCTAssertNotEqual(a, b)
    }

    /// Different salts must produce different keys for the same
    /// passphrase. This is what protects against precomputation /
    /// rainbow tables.
    func testDiffersBySalt() throws {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let saltA = Data(repeating: 0x02, count: 16)
        let saltB = Data(repeating: 0x03, count: 16)
        let a = try Argon2.deriveKey(passphrase: "pw", salt: saltA, params: params)
        let b = try Argon2.deriveKey(passphrase: "pw", salt: saltB, params: params)
        XCTAssertNotEqual(a, b)
    }

    /// Custom key length is honored.
    func testRespectsKeyLength() throws {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let salt = Data(repeating: 0x02, count: 16)
        let key16 = try Argon2.deriveKey(passphrase: "pw", salt: salt, params: params, keyLength: 16)
        let key64 = try Argon2.deriveKey(passphrase: "pw", salt: salt, params: params, keyLength: 64)
        XCTAssertEqual(key16.count, 16)
        XCTAssertEqual(key64.count, 64)
    }

    /// Invalid parameters surface as a thrown error rather than a
    /// silent zero key. Salt < 8 bytes is the cleanest trip-wire.
    func testRejectsTooShortSalt() {
        let params = Argon2.Params(timeCost: 1, memoryCostKiB: 1024, parallelism: 1)
        let shortSalt = Data(repeating: 0x02, count: 4)
        XCTAssertThrowsError(try Argon2.deriveKey(passphrase: "pw", salt: shortSalt, params: params))
    }
}
