import XCTest
import CryptoKit
@testable import todarchy

final class ShareKeysMapTests: XCTestCase {

    // MARK: - Round trip

    func testEmptyMapRoundtrips() throws {
        let master = CryptoBox.generateKey()
        let envelope = try ShareKeysMap.empty.seal(with: master)
        let opened = try ShareKeysMap.open(envelope, with: master)
        XCTAssertEqual(opened, ShareKeysMap.empty)
        XCTAssertTrue(opened.keys.isEmpty)
    }

    func testRoundtripWithMultipleKeys() throws {
        let master = CryptoBox.generateKey()
        var map = ShareKeysMap.empty
        let kGrocery = CryptoBox.generateKey()
        let kWedding = CryptoBox.generateKey()
        map.setKey(kGrocery, for: "p_grocery")
        map.setKey(kWedding, for: "p_wedding")

        let envelope = try map.seal(with: master)
        let opened = try ShareKeysMap.open(envelope, with: master)

        XCTAssertEqual(opened.keys.count, 2)
        XCTAssertEqual(opened.key(for: "p_grocery")?.withUnsafeBytes { Data($0) },
                       kGrocery.withUnsafeBytes { Data($0) })
        XCTAssertEqual(opened.key(for: "p_wedding")?.withUnsafeBytes { Data($0) },
                       kWedding.withUnsafeBytes { Data($0) })
    }

    // MARK: - Failure modes

    /// Opening with the wrong master key must fail with the standard
    /// `CryptoBox` decryption error — this is what a device sees when
    /// the user typed the wrong passphrase.
    func testWrongMasterKeyFails() throws {
        let master = CryptoBox.generateKey()
        let wrong  = CryptoBox.generateKey()
        var map = ShareKeysMap.empty
        map.setKey(CryptoBox.generateKey(), for: "p_grocery")

        let envelope = try map.seal(with: master)
        XCTAssertThrowsError(try ShareKeysMap.open(envelope, with: wrong)) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .decryptionFailed)
        }
    }

    /// Any single-byte tamper inside the ciphertext or tag must trip
    /// the AEAD's integrity check. Magic / version bytes have their
    /// own error paths.
    func testTamperFailsOpen() throws {
        let master = CryptoBox.generateKey()
        var map = ShareKeysMap.empty
        map.setKey(CryptoBox.generateKey(), for: "p_grocery")

        var envelope = try map.seal(with: master)
        // Flip a bit somewhere inside the ciphertext (past the header).
        let idx = envelope.startIndex + CryptoBox.headerSize + 2
        envelope[idx] ^= 0x01

        XCTAssertThrowsError(try ShareKeysMap.open(envelope, with: master))
    }

    /// A version field we don't recognise must be rejected, not
    /// silently treated as v1. Constructed by hand because there's no
    /// way to get the current encoder to emit a different version.
    func testRejectsUnsupportedVersion() throws {
        let master = CryptoBox.generateKey()
        let fakeJson = #"{"version": 99, "keys": {}}"#.data(using: .utf8)!
        let envelope = try CryptoBox.seal(fakeJson, with: master)
        XCTAssertThrowsError(try ShareKeysMap.open(envelope, with: master)) { error in
            XCTAssertEqual(error as? ShareKeysMap.DecodeError, .unsupportedVersion(99))
        }
    }

    /// Keys must be exactly 32 bytes. A truncated key in a hand-built
    /// payload (or one written by a buggy peer client) should error
    /// out clearly rather than crash later when we wrap it in a
    /// `SymmetricKey`.
    func testRejectsMalformedKeyLength() throws {
        let master = CryptoBox.generateKey()
        let shortKeyB64 = Data(repeating: 0xAA, count: 16).base64EncodedString()
        let fakeJson = #"{"version": 1, "keys": {"p_x": "\#(shortKeyB64)"}}"#.data(using: .utf8)!
        let envelope = try CryptoBox.seal(fakeJson, with: master)
        XCTAssertThrowsError(try ShareKeysMap.open(envelope, with: master)) { error in
            if case .malformedKey(let pid, let expected, let got) = error as? ShareKeysMap.DecodeError {
                XCTAssertEqual(pid, "p_x")
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(got, 16)
            } else {
                XCTFail("Expected .malformedKey, got \(error)")
            }
        }
    }

    // MARK: - Mutating helpers

    func testSetReplacesExistingKey() {
        var map = ShareKeysMap.empty
        let k1 = CryptoBox.generateKey()
        let k2 = CryptoBox.generateKey()
        map.setKey(k1, for: "p_x")
        XCTAssertEqual(map.key(for: "p_x")?.withUnsafeBytes { Data($0) },
                       k1.withUnsafeBytes { Data($0) })
        map.setKey(k2, for: "p_x")
        XCTAssertEqual(map.keys.count, 1)
        XCTAssertEqual(map.key(for: "p_x")?.withUnsafeBytes { Data($0) },
                       k2.withUnsafeBytes { Data($0) })
    }

    func testRemoveDeletesEntry() {
        var map = ShareKeysMap.empty
        map.setKey(CryptoBox.generateKey(), for: "p_x")
        map.setKey(CryptoBox.generateKey(), for: "p_y")
        map.remove(projectId: "p_x")
        XCTAssertNil(map.key(for: "p_x"))
        XCTAssertNotNil(map.key(for: "p_y"))
    }
}
