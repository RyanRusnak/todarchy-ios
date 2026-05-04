import Foundation
import CryptoKit

/// Stateless coordinator for shared-project files living alongside the
/// main `tasks.automerge` in the user's sync folder. Combines three
/// primitives that the app's higher layers need to touch as a unit:
///
///   - **filesystem layout** — where does the encrypted file live
///   - **key storage** — the symmetric key for encrypt/decrypt
///   - **PerProjectStore construction** — opening the doc
///
/// The manager doesn't cache anything; each call is independent. Higher
/// layers (TaskStore in Phase 3c) can cache per-project stores
/// themselves if they want.
struct SharedProjectManager {
    /// The sync-folder URL where `tasks.automerge` lives. Shared
    /// project files are siblings of the main doc so any file-sync
    /// daemon watching the folder picks them up automatically.
    let folder: URL
    let keyStore: KeyStore

    enum ManagerError: Error, LocalizedError, Equatable {
        case fileExists(URL)
        case keyAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .fileExists(let url): return "Shared file already exists at \(url.path)."
            case .keyAlreadyExists(let id): return "A key is already registered for project \(id)."
            }
        }
    }

    /// Canonical URL for a shared project's encrypted doc.
    func fileURL(for projectId: String) -> URL {
        folder.appendingPathComponent(PerProjectStore.filename(for: projectId))
    }

    /// First-time promotion: generate a key, seed the encrypted file
    /// with the project's existing tasks + metadata, stash the key.
    /// Throws if the target file already exists or a key is already
    /// registered — the caller should route to `openStore(for:)`
    /// instead.
    @discardableResult
    func createShared(project: ProjectItem,
                      tasks: [TaskItem]) throws -> (fileURL: URL, key: SymmetricKey) {
        let url = fileURL(for: project.id)
        if FileManager.default.fileExists(atPath: url.path) {
            throw ManagerError.fileExists(url)
        }
        if keyStore.load(for: project.id) != nil {
            throw ManagerError.keyAlreadyExists(project.id)
        }

        let key = CryptoBox.generateKey()
        try keyStore.save(key, for: project.id)
        var shared = project
        shared.isShared = true
        let store = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        try store.save(.init(tasks: tasks, project: shared))
        return (url, key)
    }

    /// Open an existing shared store. Returns nil when there's no key
    /// for this project id in the key store (meaning this device
    /// hasn't joined the project, even if the encrypted file happens
    /// to be in the folder).
    func openStore(for projectId: String) -> PerProjectStore? {
        guard let key = keyStore.load(for: projectId) else { return nil }
        return PerProjectStore(fileURL: fileURL(for: projectId), projectId: projectId, key: key)
    }

    /// Accept a shared-project invitation: persist the key under the
    /// project id. The encrypted file itself is expected to land via
    /// the sync transport (Dropbox, iCloud, future relay). Returns a
    /// store wrapping whatever's on disk right now — might be empty
    /// if we arrived before the file did.
    @discardableResult
    func accept(payload: ShareLink.Payload) throws -> PerProjectStore {
        try keyStore.save(payload.key, for: payload.projectId)
        return PerProjectStore(
            fileURL: fileURL(for: payload.projectId),
            projectId: payload.projectId,
            key: payload.key
        )
    }

    /// Forget a shared project locally — delete the key and the file.
    /// Peers still have their copies; this is "leave," not "delete
    /// everywhere." A true multi-device delete would tombstone inside
    /// the shared doc itself, which is a Phase-5 concern.
    func forgetLocally(projectId: String) throws {
        keyStore.delete(for: projectId)
        let url = fileURL(for: projectId)
        try? FileManager.default.removeItem(at: url)
    }

    /// List the project ids of shared files present in the folder,
    /// regardless of whether this device has the keys.
    func knownSharedProjectIds() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        return entries.compactMap { PerProjectStore.projectId(fromFilename: $0) }
    }
}
