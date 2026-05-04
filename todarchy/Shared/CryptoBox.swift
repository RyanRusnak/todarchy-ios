import Foundation
import CryptoKit

/// Symmetric envelope for shared Automerge docs.
///
/// The design goal is "key-as-capability sharing": anyone holding the key
/// can read and write a shared project, and anyone without it sees only
/// opaque bytes. Whether those bytes travel through Dropbox, iCloud
/// Drive, or a future relay server is a transport detail — the envelope
/// is the same.
///
/// ## Envelope layout
///
///     ┌────────┬──────┬────────┬────────────────────┬──────────┐
///     │ "TDAR" │ ver  │ nonce  │    ciphertext      │ auth tag │
///     │  4B    │  1B  │  12B   │    variable        │   16B    │
///     └────────┴──────┴────────┴────────────────────┴──────────┘
///
/// - **magic** "TDAR" lets a parser reject junk bytes without trying to
///   decrypt them (helpful when scanning a directory for our files).
/// - **version** is for future migrations (new cipher, header fields).
/// - **nonce** is a fresh 96-bit value per seal; stored in the clear is
///   fine (non-secret, required for open).
/// - **ciphertext + tag** is the ChaCha20-Poly1305 AEAD output.
///
/// ChaCha20-Poly1305 was chosen over AES-GCM because its security
/// properties under nonce reuse are slightly less catastrophic and its
/// software implementations are constant-time everywhere (no AES-NI
/// requirement). CryptoKit provides both; either would work.
enum CryptoBox {
    /// The 4-byte magic that prefixes every envelope.
    static let magic: [UInt8] = Array("TDAR".utf8)
    /// Envelope version. Bump when the layout or cipher changes.
    static let currentVersion: UInt8 = 1
    static let nonceSize = 12
    static let tagSize = 16
    static let headerSize = 4 + 1 + 12        // magic + version + nonce
    static let minimumEnvelopeSize = headerSize + tagSize

    enum BoxError: Error, LocalizedError, Equatable {
        case badMagic
        case unsupportedVersion(UInt8)
        case truncated
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .badMagic: return "Not a todarchy encrypted envelope (magic bytes missing)."
            case .unsupportedVersion(let v): return "Unsupported envelope version \(v)."
            case .truncated: return "Envelope bytes are truncated."
            case .decryptionFailed: return "Decryption failed — wrong key or tampered bytes."
            }
        }
    }

    // MARK: - Seal (encrypt)

    /// Encrypts `plaintext` under `key`, producing a full envelope (magic +
    /// header + ciphertext + tag).
    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        // A fresh random nonce per seal is mandatory — ChaCha20-Poly1305
        // loses all confidentiality if a (key, nonce) pair is ever
        // reused. `ChaChaPoly.Nonce()` initializes with secure random.
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        var envelope = Data()
        envelope.reserveCapacity(headerSize + sealed.ciphertext.count + tagSize)
        envelope.append(contentsOf: magic)
        envelope.append(currentVersion)
        envelope.append(contentsOf: Data(nonce))
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    // MARK: - Open (decrypt)

    /// Decrypts a previously-sealed envelope. Throws on tamper, wrong
    /// key, unknown version, or malformed bytes.
    static func open(_ envelope: Data, with key: SymmetricKey) throws -> Data {
        guard envelope.count >= minimumEnvelopeSize else { throw BoxError.truncated }

        // Peel off header
        guard Array(envelope.prefix(4)) == magic else { throw BoxError.badMagic }
        let version = envelope[envelope.startIndex + 4]
        guard version == currentVersion else { throw BoxError.unsupportedVersion(version) }

        // Nonce + ciphertext + tag are the rest. Slice carefully — Data
        // indices aren't zero-based when the Data is a subrange.
        let nonceStart = envelope.startIndex + 5
        let nonceEnd = nonceStart + nonceSize
        let nonceBytes = envelope[nonceStart..<nonceEnd]

        let tagStart = envelope.endIndex - tagSize
        let ciphertext = envelope[nonceEnd..<tagStart]
        let tag = envelope[tagStart..<envelope.endIndex]

        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        } catch {
            throw BoxError.truncated
        }

        do {
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(sealed, using: key)
        } catch {
            throw BoxError.decryptionFailed
        }
    }

    // MARK: - Key helpers

    /// Fresh 256-bit key for a new shared project.
    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// URL-safe base64 encoding of a key — what we put in a share link.
    /// Uses base64url (no `+`, `/`, `=`) so it's drop-safe in URL fragments.
    static func encode(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return raw.base64URLEncodedString
    }

    /// Parse a key from a share-link fragment. Returns nil if the string
    /// isn't a valid base64url-encoded 256-bit key.
    static func decodeKey(from encoded: String) -> SymmetricKey? {
        guard let raw = Data(base64URLEncoded: encoded), raw.count == 32 else { return nil }
        return SymmetricKey(data: raw)
    }

    // MARK: - Envelope probing

    /// True iff `data` looks like a todarchy envelope (correct magic,
    /// known version, large enough). Does NOT verify the auth tag —
    /// that requires the key.
    static func isEnvelope(_ data: Data) -> Bool {
        guard data.count >= minimumEnvelopeSize,
              Array(data.prefix(4)) == magic else { return false }
        let version = data[data.startIndex + 4]
        return version == currentVersion
    }
}

// MARK: - base64url helpers

private extension Data {
    /// RFC 4648 §5 "base64url" with no padding.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded: String) {
        var s = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad back to a multiple of 4.
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        self.init(base64Encoded: s)
    }
}
