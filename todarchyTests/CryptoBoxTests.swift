import XCTest
import CryptoKit
@testable import todarchy

final class CryptoBoxTests: XCTestCase {

    // MARK: - Round-trip

    func testSealThenOpenRecoversPlaintext() throws {
        let key = CryptoBox.generateKey()
        let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)
        let envelope = try CryptoBox.seal(plaintext, with: key)
        let recovered = try CryptoBox.open(envelope, with: key)
        XCTAssertEqual(recovered, plaintext)
    }

    func testLargePayloadRoundTrip() throws {
        let key = CryptoBox.generateKey()
        // Roughly a representative-sized Automerge doc (200KB).
        var plaintext = Data(count: 200_000)
        plaintext.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let envelope = try CryptoBox.seal(plaintext, with: key)
        let recovered = try CryptoBox.open(envelope, with: key)
        XCTAssertEqual(recovered, plaintext)
    }

    func testEmptyPayloadRoundTrips() throws {
        let key = CryptoBox.generateKey()
        let envelope = try CryptoBox.seal(Data(), with: key)
        XCTAssertEqual(try CryptoBox.open(envelope, with: key), Data())
    }

    func testFreshNoncePerSeal() throws {
        // Same plaintext + same key must produce different ciphertexts
        // each time. This is the most important invariant for AEAD
        // security — nonce reuse destroys confidentiality.
        let key = CryptoBox.generateKey()
        let plaintext = Data("hello world".utf8)
        let a = try CryptoBox.seal(plaintext, with: key)
        let b = try CryptoBox.seal(plaintext, with: key)
        XCTAssertNotEqual(a, b, "Every seal must pick a fresh nonce.")
    }

    // MARK: - Tamper detection

    func testTamperingCiphertextFails() throws {
        let key = CryptoBox.generateKey()
        var envelope = try CryptoBox.seal(Data("secrets".utf8), with: key)
        // Flip a byte inside the ciphertext region.
        let flipIndex = envelope.startIndex + CryptoBox.headerSize + 1
        envelope[flipIndex] ^= 0xFF
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: key)) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .decryptionFailed)
        }
    }

    func testTamperingTagFails() throws {
        let key = CryptoBox.generateKey()
        var envelope = try CryptoBox.seal(Data("secrets".utf8), with: key)
        envelope[envelope.endIndex - 1] ^= 0xFF
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: key)) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .decryptionFailed)
        }
    }

    func testWrongKeyFails() throws {
        let keyA = CryptoBox.generateKey()
        let keyB = CryptoBox.generateKey()
        let envelope = try CryptoBox.seal(Data("secrets".utf8), with: keyA)
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: keyB)) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .decryptionFailed)
        }
    }

    // MARK: - Header validation

    func testBadMagicRejected() {
        var garbage = Data("HELLO".utf8)
        garbage.append(contentsOf: Array(repeating: UInt8(0), count: CryptoBox.minimumEnvelopeSize))
        XCTAssertThrowsError(try CryptoBox.open(garbage, with: CryptoBox.generateKey())) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .badMagic)
        }
    }

    func testUnsupportedVersionRejected() throws {
        let key = CryptoBox.generateKey()
        var envelope = try CryptoBox.seal(Data("ok".utf8), with: key)
        // Version byte is right after the 4 magic bytes.
        envelope[envelope.startIndex + 4] = 0xFE
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: key)) { error in
            if case .unsupportedVersion(let v) = (error as? CryptoBox.BoxError) {
                XCTAssertEqual(v, 0xFE)
            } else {
                XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testTruncatedRejected() {
        let tooShort = Data(repeating: 0, count: 5)
        XCTAssertThrowsError(try CryptoBox.open(tooShort, with: CryptoBox.generateKey())) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .truncated)
        }
    }

    // MARK: - Envelope probe

    func testIsEnvelopeRecognizesOurBytes() throws {
        let env = try CryptoBox.seal(Data("abc".utf8), with: CryptoBox.generateKey())
        XCTAssertTrue(CryptoBox.isEnvelope(env))
    }

    func testIsEnvelopeRejectsAutomergeBytes() {
        // Real Automerge files start with their own magic. Just make
        // sure `isEnvelope` isn't trigger-happy on arbitrary bytes.
        let automergeLike = Data([0x85, 0x6f, 0x4a, 0x83] + Array(repeating: UInt8(0), count: 200))
        XCTAssertFalse(CryptoBox.isEnvelope(automergeLike))
    }

    // MARK: - Key encode/decode

    func testKeyEncodeDecodeRoundTrip() {
        let key = CryptoBox.generateKey()
        let encoded = CryptoBox.encode(key)
        // base64url: no '+', '/', or '=' so share links are drop-safe.
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        let decoded = CryptoBox.decodeKey(from: encoded)
        XCTAssertNotNil(decoded)
        // Prove we can seal with one and open with the other.
        let envelope = try! CryptoBox.seal(Data("round trip".utf8), with: key)
        let plaintext = try! CryptoBox.open(envelope, with: decoded!)
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), "round trip")
    }

    func testDecodeKeyRejectsGarbage() {
        XCTAssertNil(CryptoBox.decodeKey(from: "not-a-real-key"))
        XCTAssertNil(CryptoBox.decodeKey(from: ""))
        // 16 bytes — valid base64url but wrong length (we want 32).
        XCTAssertNil(CryptoBox.decodeKey(from: "AAAAAAAAAAAAAAAAAAAAAA"))
    }

    // MARK: - v2: salt carried in the clear header

    func testSaltedEnvelopeRoundTrips() throws {
        let key = CryptoBox.generateKey()
        let salt = Data((0..<16).map { UInt8($0) })
        let envelope = try CryptoBox.seal(Data("payload".utf8), with: key, salt: salt)
        XCTAssertEqual(try CryptoBox.open(envelope, with: key), Data("payload".utf8))
    }

    func testSaltIsReadableWithoutTheKey() throws {
        // The whole point of v2: a device holding only the passphrase can
        // recover the KDF salt, which otherwise lives inside the very doc
        // it can't decrypt yet.
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let envelope = try CryptoBox.seal(Data("secret".utf8),
                                          with: CryptoBox.generateKey(),
                                          salt: salt)
        XCTAssertEqual(CryptoBox.salt(in: envelope), salt)
    }

    func testSaltedEnvelopeStillHidesThePlaintext() throws {
        let salt = Data(repeating: 0xAB, count: 16)
        let envelope = try CryptoBox.seal(Data("topsecret".utf8),
                                          with: CryptoBox.generateKey(),
                                          salt: salt)
        XCTAssertNil(envelope.range(of: Data("topsecret".utf8)),
                     "Only the header is public — the body must not be.")
    }

    func testV1EnvelopeHasNoSalt() throws {
        let envelope = try CryptoBox.seal(Data("x".utf8), with: CryptoBox.generateKey())
        XCTAssertNil(CryptoBox.salt(in: envelope))
        XCTAssertEqual(envelope[envelope.startIndex + 4], CryptoBox.currentVersion)
    }

    func testBothVersionsProbeAsEnvelopes() throws {
        let key = CryptoBox.generateKey()
        let v1 = try CryptoBox.seal(Data("a".utf8), with: key)
        let v2 = try CryptoBox.seal(Data("a".utf8), with: key, salt: Data(repeating: 1, count: 16))
        XCTAssertTrue(CryptoBox.isEnvelope(v1))
        XCTAssertTrue(CryptoBox.isEnvelope(v2))
    }

    func testSaltedEnvelopeRejectsTheWrongKey() throws {
        let envelope = try CryptoBox.seal(Data("s".utf8),
                                          with: CryptoBox.generateKey(),
                                          salt: Data(repeating: 2, count: 16))
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: CryptoBox.generateKey()))
    }

    func testSealRejectsAMisSizedSalt() {
        XCTAssertThrowsError(try CryptoBox.seal(Data("x".utf8),
                                                with: CryptoBox.generateKey(),
                                                salt: Data(repeating: 0, count: 8)))
    }

    func testUnknownVersionIsNotAnEnvelope() throws {
        var envelope = try CryptoBox.seal(Data("x".utf8), with: CryptoBox.generateKey())
        envelope[envelope.startIndex + 4] = 99
        XCTAssertFalse(CryptoBox.isEnvelope(envelope))
        XCTAssertThrowsError(try CryptoBox.open(envelope, with: CryptoBox.generateKey())) { error in
            XCTAssertEqual(error as? CryptoBox.BoxError, .unsupportedVersion(99))
        }
    }
}
