import XCTest
import CryptoKit
@testable import todarchy

final class ShareLinkTests: XCTestCase {

    // MARK: - Encode

    func testEncodeProducesExpectedShape() {
        let key = CryptoBox.generateKey()
        let url = ShareLink.encode(projectId: "p_abc12345", key: key)

        XCTAssertEqual(url.scheme, "todarchy")
        XCTAssertEqual(url.host, "share")
        XCTAssertEqual(url.path, "/p_abc12345")
        XCTAssertNotNil(url.fragment)
        XCTAssertTrue(url.fragment!.hasPrefix("k="))
    }

    func testEncodePercentEncodesFunnyProjectIds() {
        let key = CryptoBox.generateKey()
        let url = ShareLink.encode(projectId: "p with space", key: key)
        // The path component shouldn't contain literal spaces.
        XCTAssertFalse(url.absoluteString.contains(" "))
        // Round-trip must still decode back to the original id.
        let decoded = try! ShareLink.decode(url).get()
        XCTAssertEqual(decoded.projectId, "p with space")
    }

    func testKeyLivesInFragmentNotQuery() {
        // Critical for privacy: keys must be in the fragment so they
        // never hit servers during HTTP redirects.
        let key = CryptoBox.generateKey()
        let url = ShareLink.encode(projectId: "p_x", key: key)
        XCTAssertNil(url.query)
        XCTAssertFalse(url.absoluteString.contains("?k="))
    }

    // MARK: - Decode

    func testDecodeRecoversProjectIdAndKey() throws {
        let key = CryptoBox.generateKey()
        let url = ShareLink.encode(projectId: "p_abc", key: key)

        let payload = try ShareLink.decode(url).get()
        XCTAssertEqual(payload.projectId, "p_abc")
        // Prove round-trip via decrypt — sealed with original, opened
        // with the decoded key.
        let sealed = try CryptoBox.seal(Data("hi".utf8), with: key)
        XCTAssertEqual(try CryptoBox.open(sealed, with: payload.key), Data("hi".utf8))
    }

    func testDecodeFromStringRoundTrip() throws {
        let key = CryptoBox.generateKey()
        let urlString = ShareLink.encode(projectId: "p_abc", key: key).absoluteString

        let payload = try ShareLink.decode(urlString).get()
        XCTAssertEqual(payload.projectId, "p_abc")
    }

    func testDecodeRejectsWrongScheme() {
        let url = URL(string: "https://example.com/share/p_abc#k=AAAA")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.wrongScheme))
    }

    func testDecodeRejectsNonShareHost() {
        let url = URL(string: "todarchy://other/p_abc#k=AAAA")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.malformedPath))
    }

    func testDecodeRejectsMissingProjectId() {
        let url = URL(string: "todarchy://share/#k=AAAA")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.malformedPath))
    }

    func testDecodeRejectsMissingFragment() {
        let url = URL(string: "todarchy://share/p_abc")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.missingKey))
    }

    func testDecodeRejectsFragmentWithoutKeyPart() {
        let url = URL(string: "todarchy://share/p_abc#foo=bar")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.missingKey))
    }

    func testDecodeRejectsInvalidKeyBytes() {
        // Too few bytes — valid base64url but not a 256-bit key.
        let url = URL(string: "todarchy://share/p_abc#k=AAAAAA")!
        let result = ShareLink.decode(url)
        XCTAssertEqual(result, .failure(.badKey))
    }

    func testDecodeIgnoresExtraFragmentKeys() throws {
        // Forward-compat: future versions may add fragment metadata
        // (expiry, permissions). Older clients should still read the
        // key and ignore the rest.
        let key = CryptoBox.generateKey()
        let encoded = CryptoBox.encode(key)
        let url = URL(string: "todarchy://share/p_abc#k=\(encoded)&v=2&exp=1730000000")!
        let payload = try ShareLink.decode(url).get()
        XCTAssertEqual(payload.projectId, "p_abc")
    }
}
