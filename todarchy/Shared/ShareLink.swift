import Foundation
import CryptoKit

/// Encode/decode share links for shared projects.
///
/// Format:
///
///     todarchy://share/<projectId>#k=<base64url-key>
///
/// The key lives in the URL **fragment** specifically — fragments are
/// never sent to HTTP servers even if a link is rewritten through an
/// https landing page, so a future web-based "open this in todarchy"
/// redirect can't accidentally leak keys into server logs.
///
/// The custom scheme (`todarchy://`) is registered in the app's
/// Info.plist by `generate_project.rb`; the OS delivers matching URLs
/// to the app via `onOpenURL`.
enum ShareLink {
    static let scheme = "todarchy"
    static let sharePathPrefix = "share/"

    struct Payload: Equatable {
        let projectId: String
        let key: SymmetricKey

        /// Equatable compares the key bytes, not the identity of the
        /// `SymmetricKey` wrapper.
        static func == (lhs: Payload, rhs: Payload) -> Bool {
            guard lhs.projectId == rhs.projectId else { return false }
            let a = lhs.key.withUnsafeBytes { Data($0) }
            let b = rhs.key.withUnsafeBytes { Data($0) }
            return a == b
        }
    }

    enum DecodeError: Error, LocalizedError, Equatable {
        case wrongScheme
        case malformedPath
        case missingKey
        case badKey

        var errorDescription: String? {
            switch self {
            case .wrongScheme: return "Not a todarchy share link."
            case .malformedPath: return "Share link is missing the project id."
            case .missingKey: return "Share link has no key fragment (#k=…)."
            case .badKey: return "Share link's key isn't a valid 256-bit value."
            }
        }
    }

    // MARK: - Encode

    static func encode(projectId: String, key: SymmetricKey) -> URL {
        let encoded = CryptoBox.encode(key)
        // Percent-encode the project id for safety — ids are usually
        // `p_<8hex>` but the API accepts arbitrary strings, so don't
        // assume URL-safety.
        let safeId = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? projectId
        var components = URLComponents()
        components.scheme = scheme
        components.host = "share"
        components.path = "/\(safeId)"
        components.fragment = "k=\(encoded)"
        // Components-based construction gives us a canonical URL; force-unwrap
        // is safe because every field is valid by construction.
        return components.url!
    }

    // MARK: - Decode

    static func decode(_ url: URL) -> Result<Payload, DecodeError> {
        guard url.scheme == scheme else { return .failure(.wrongScheme) }

        // Project id lives in the path. URLComponents gives us the
        // host="share" + path="/<id>" shape.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "share" else {
            return .failure(.malformedPath)
        }
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return .failure(.malformedPath) }
        let projectId = trimmedPath.removingPercentEncoding ?? trimmedPath

        // Fragment format: k=<base64url>. Nothing else supported yet;
        // we'll extend this if we ever add more metadata (e.g. invite
        // expiry, permission hints).
        guard let fragment = components.fragment, !fragment.isEmpty else {
            return .failure(.missingKey)
        }
        guard let keyPart = fragmentValue(for: "k", in: fragment) else {
            return .failure(.missingKey)
        }
        guard let key = CryptoBox.decodeKey(from: keyPart) else {
            return .failure(.badKey)
        }
        return .success(Payload(projectId: projectId, key: key))
    }

    static func decode(_ string: String) -> Result<Payload, DecodeError> {
        guard let url = URL(string: string) else { return .failure(.wrongScheme) }
        return decode(url)
    }

    // MARK: -

    /// Parse `k=...&foo=bar` style fragments. Robust against future
    /// extra keys without breaking older clients — we ignore what we
    /// don't recognize.
    private static func fragmentValue(for name: String, in fragment: String) -> String? {
        for part in fragment.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0] == Substring(name) else { continue }
            return String(kv[1])
        }
        return nil
    }
}
