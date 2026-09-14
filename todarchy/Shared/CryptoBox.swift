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
/// Version 1 — shared projects, where the key arrives out of band in a
/// share link, so nothing about the KDF needs to travel with the bytes:
///
///     ┌────────┬──────┬────────┬────────────────────┬──────────┐
///     │ "TDAR" │ ver=1│ nonce  │    ciphertext      │ auth tag │
///     │  4B    │  1B  │  12B   │    variable        │   16B    │
///     └────────┴──────┴────────┴────────────────────┴──────────┘
///
/// Version 2 — the main doc on the relay, which is sealed under the
/// passphrase-derived master key:
///
///     ┌────────┬──────┬────────┬────────┬─────────────┬──────────┐
///     │ "TDAR" │ ver=2│  salt  │ nonce  │  ciphertext │ auth tag │
///     │  4B    │  1B  │  16B   │  12B   │   variable  │   16B    │
///     └────────┴──────┴────────┴────────┴─────────────┴──────────┘
///
/// - **magic** "TDAR" lets a parser reject junk bytes without trying to
///   decrypt them (helpful when scanning a directory for our files).
/// - **version** selects the header layout.
/// - **salt** (v2 only) is the Argon2 salt the master key was derived
///   from. It has to ride along in the clear: the salt normally lives
///   inside the main doc, and a device holding only the passphrase
///   can't read the doc until it has derived the key — which it can't
///   do without the salt. Salts are non-secret by construction, so
///   publishing it costs nothing. See `salt(in:)`.
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
    /// Envelope version for a key delivered out of band (shared projects).
    static let currentVersion: UInt8 = 1
    /// Envelope version that carries the KDF salt in the clear header,
    /// for payloads sealed under the passphrase-derived master key.
    static let saltedVersion: UInt8 = 2
    static let nonceSize = 12
    static let tagSize = 16
    static let saltSize = 16
    static let headerSize = 4 + 1 + 12        // magic + version + nonce
    static let saltedHeaderSize = headerSize + saltSize
    static let minimumEnvelopeSize = headerSize + tagSize

    /// Bytes between the start of the envelope and the ciphertext, for a
    /// given version. `nil` for versions we don't know how to parse.
    static func headerSize(forVersion version: UInt8) -> Int? {
        switch version {
        case currentVersion: return headerSize
        case saltedVersion:  return saltedHeaderSize
        default:             return nil
        }
    }

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
    ///
    /// Pass `salt` when `key` was derived from a passphrase and the reader
    /// will need that salt to re-derive it — this emits a v2 envelope with
    /// the salt in the clear header. Omit it for keys shared out of band,
    /// which emits the v1 layout.
    static func seal(_ plaintext: Data, with key: SymmetricKey, salt: Data? = nil) throws -> Data {
        if let salt, salt.count != saltSize { throw BoxError.truncated }
        // A fresh random nonce per seal is mandatory — ChaCha20-Poly1305
        // loses all confidentiality if a (key, nonce) pair is ever
        // reused. `ChaChaPoly.Nonce()` initializes with secure random.
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        var envelope = Data()
        envelope.reserveCapacity(
            (salt == nil ? headerSize : saltedHeaderSize) + sealed.ciphertext.count + tagSize
        )
        envelope.append(contentsOf: magic)
        envelope.append(salt == nil ? currentVersion : saltedVersion)
        if let salt { envelope.append(salt) }
        envelope.append(contentsOf: Data(nonce))
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    // MARK: - Open (decrypt)

    /// Decrypts a previously-sealed envelope. Throws on tamper, wrong
    /// key, unknown version, or malformed bytes.
    static func open(_ envelope: Data, with key: SymmetricKey) throws -> Data {
        // Length first: a buffer too small to be even a minimal v1
        // envelope is truncated, not mis-magicked. v2 envelopes carry an
        // extra 16-byte salt, so they clear this bar comfortably and get
        // their exact length checked below.
        guard envelope.count >= minimumEnvelopeSize else { throw BoxError.truncated }

        // Peel off header
        guard Array(envelope.prefix(4)) == magic else { throw BoxError.badMagic }
        let version = envelope[envelope.startIndex + 4]
        guard let header = headerSize(forVersion: version) else {
            throw BoxError.unsupportedVersion(version)
        }
        guard envelope.count >= header + tagSize else { throw BoxError.truncated }

        // Nonce + ciphertext + tag are the rest. Slice carefully — Data
        // indices aren't zero-based when the Data is a subrange. The nonce
        // is always the last field of the header, whatever precedes it.
        let nonceStart = envelope.startIndex + header - nonceSize
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

    /// True iff `data` looks like a todarchy envelope of any known version
    /// (correct magic, known version, large enough). Does NOT verify the
    /// auth tag — that requires the key.
    static func isEnvelope(_ data: Data) -> Bool {
        guard data.count >= magic.count + 1,
              Array(data.prefix(4)) == magic else { return false }
        guard let header = headerSize(forVersion: data[data.startIndex + 4]) else { return false }
        return data.count >= header + tagSize
    }

    /// Read the KDF salt out of a v2 envelope **without the key** — the
    /// bootstrap step for a device that has the passphrase but has never
    /// seen the doc. Returns nil for v1 envelopes and for non-envelopes.
    static func salt(in envelope: Data) -> Data? {
        guard envelope.count >= saltedHeaderSize,
              Array(envelope.prefix(4)) == magic,
              envelope[envelope.startIndex + 4] == saltedVersion else { return nil }
        let start = envelope.startIndex + magic.count + 1
        return Data(envelope[start..<(start + saltSize)])
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
