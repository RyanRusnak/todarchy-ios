import Foundation
import CryptoKit

/// In-memory shape of the per-user `shareKeys` field that lives inside
/// the main Automerge doc. Sealed (`ChaChaPoly` via `CryptoBox`) under
/// the user's passphrase-derived master key before being written to
/// `shareKeys.cipher`. Reading is the reverse: pull `cipher` bytes out
/// of the doc, open with the master key, decode JSON.
///
/// Cross-platform note: the JSON encoding is the wire format between
/// the Swift app and the Linux companion, so any change here is a
/// coordinated schema bump.
struct ShareKeysMap: Codable, Equatable {
    /// Wire-format version. Bump on incompatible JSON shape changes.
    /// The outer Automerge `shareKeys.version` mirrors this so a
    /// device can decide whether it's looking at a format it knows.
    var version: Int

    /// `projectId → raw key bytes (32)`. Codable serializes Data as
    /// base64 by default, which gives us compact JSON without us
    /// reaching for a custom encoder.
    var keys: [String: Data]

    static let currentVersion: Int = 1

    static let empty = ShareKeysMap(version: ShareKeysMap.currentVersion, keys: [:])

    enum DecodeError: Error, LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case malformedKey(projectId: String, expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "Unsupported shareKeys version \(v)."
            case let .malformedKey(projectId, expected, got):
                return "Stored key for \(projectId) has \(got) bytes, expected \(expected)."
            }
        }
    }

    // MARK: - Seal / open

    /// Encode to JSON and seal with the master key, producing a single
    /// blob suitable for `shareKeys.cipher`.
    func seal(with masterKey: SymmetricKey) throws -> Data {
        let json = try JSONEncoder().encode(self)
        return try CryptoBox.seal(json, with: masterKey)
    }

    /// Decrypt an envelope with `masterKey` and decode the JSON inside.
    /// Throws on wrong key (`CryptoBox.BoxError.decryptionFailed`),
    /// truncation, tamper, malformed JSON, or unknown version.
    static func open(_ envelope: Data, with masterKey: SymmetricKey) throws -> ShareKeysMap {
        let plain = try CryptoBox.open(envelope, with: masterKey)
        let map = try JSONDecoder().decode(ShareKeysMap.self, from: plain)
        guard map.version == currentVersion else {
            throw DecodeError.unsupportedVersion(map.version)
        }
        // Defense in depth: keys must be exactly 32 bytes (256-bit
        // symmetric keys). Anything else is corruption or a bug in a
        // peer client.
        for (pid, key) in map.keys where key.count != 32 {
            throw DecodeError.malformedKey(projectId: pid, expected: 32, got: key.count)
        }
        return map
    }

    // MARK: - Convenience accessors

    /// Materialize a per-project key as a `SymmetricKey`. Nil if we
    /// don't have one for this project.
    func key(for projectId: String) -> SymmetricKey? {
        guard let raw = keys[projectId] else { return nil }
        return SymmetricKey(data: raw)
    }

    /// Insert or replace the key for `projectId`. Idempotent.
    mutating func setKey(_ key: SymmetricKey, for projectId: String) {
        let raw = key.withUnsafeBytes { Data($0) }
        keys[projectId] = raw
    }

    mutating func remove(projectId: String) {
        keys.removeValue(forKey: projectId)
    }
}
