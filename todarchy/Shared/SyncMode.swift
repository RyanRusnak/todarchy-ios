import Foundation
import Security

/// The sync transport currently in use. Replaces the earlier implicit
/// two-state `syncFolderURL == nil ? local-only : folder-synced` encoding
/// with a three-case enum so a new HTTP relay transport can coexist.
///
/// Switching between modes preserves the in-memory Automerge doc — the
/// `TaskStorePersistence.setFileURL(_:replaceLocalDoc:)` path carries
/// the current state across the transition.
enum SyncMode: Equatable {
    /// No sync. The doc lives in Application Support.
    case localOnly
    /// File-based sync. Mirrors `tasks.automerge` + `shared_*.automerge.enc`
    /// siblings through a user-picked folder (Dropbox, iCloud, Syncthing…).
    case folder(URL)
    /// HTTP relay. Pushes opaque bytes to a self-hostable server (see
    /// `TODARCHY_SERVER_PROMPT.md`). The local file in Application Support
    /// remains the Automerge-doc-of-record; the server is a remote mirror.
    case server(ServerConfig)

    var kind: Kind {
        switch self {
        case .localOnly: return .localOnly
        case .folder:    return .folder
        case .server:    return .server
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case localOnly, folder, server
        var id: String { rawValue }
    }
}

/// Connection details for an HTTP relay server. Persisted in UserDefaults
/// as JSON. Share the same `mainDocId` across devices for multi-device sync.
struct ServerConfig: Equatable, Codable {
    var baseURL: URL
    var mainDocId: String

    /// Server-side id regex per the spec: `^[A-Za-z0-9_\-]{1,64}$`.
    static func isValidDocId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
    }

    /// Generate a fresh main-doc id: `main_<22 url-safe base64 chars>`
    /// (16 bytes of entropy). The `main_` prefix keeps this namespace
    /// distinct from per-project ids used for shared projects.
    static func generateMainDocId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let b64 = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "main_\(b64)"
    }
}
