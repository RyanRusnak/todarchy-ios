import Foundation
import CryptoKit

/// Encrypted, file-backed Automerge doc for a single shared project.
///
/// One instance per shared-project file on disk. The on-disk bytes are
/// a `CryptoBox` envelope wrapping a standard Automerge doc using the
/// usual schema (`tasks`, `projects`, `contexts`). Since the schema is
/// shared with the main `tasks.automerge`, the Linux companion and any
/// other client can read shared projects with the same parser once
/// they hold the key.
///
/// ## Lifecycle
///
///     ┌─────────────────┐ seal()  ┌──────────────────────┐  Dropbox / iCloud /
///     │ AutomergeStore  │ ──────▶ │ shared_<id>.enc file │  Syncthing / relay
///     │ (in memory)     │ ◀────── │ (CryptoBox envelope) │◀──────── peers
///     └─────────────────┘  open() └──────────────────────┘
///
/// `merge(encryptedBytes:)` is how we absorb peer changes: decrypt
/// their envelope, merge into our live doc, re-encrypt on the next
/// save. Same pattern as `TaskStorePersistence`, with a decrypt step
/// in front.
///
/// This layer is deliberately minimal: no queue, no file watcher, no
/// security-scope plumbing. Those integrate at the `TaskStorePersistence`
/// level once we wire per-project stores into the UI (Phase 3+).
final class PerProjectStore {
    struct Snapshot: Equatable {
        /// Tasks that live in this shared project. All have
        /// `list == projectId`.
        var tasks: [TaskItem]
        /// The project's own metadata. Stored inside the encrypted doc
        /// so a recipient opening a share link gets everything — name,
        /// accent, icon — in one shot.
        var project: ProjectItem
    }

    enum StoreError: Error, LocalizedError, Equatable {
        case envelope(CryptoBox.BoxError)
        case docLoadFailed
        case missingProject

        var errorDescription: String? {
            switch self {
            case .envelope(let e): return "Envelope error: \(e.localizedDescription)"
            case .docLoadFailed: return "Decrypted bytes weren't a valid Automerge doc."
            case .missingProject: return "Shared doc didn't contain the project record."
            }
        }
    }

    let projectId: String
    let key: SymmetricKey
    private(set) var fileURL: URL
    private var automerge: AutomergeStore

    /// Construct from an on-disk file (or use a fresh blank doc if the
    /// file doesn't exist / won't decrypt). Callers that care about the
    /// difference should use `readSnapshot()` which throws on failure.
    init(fileURL: URL, projectId: String, key: SymmetricKey) {
        self.fileURL = fileURL
        self.projectId = projectId
        self.key = key
        if FileManager.default.fileExists(atPath: fileURL.path),
           let enc = try? Data(contentsOf: fileURL),
           let plain = try? CryptoBox.open(enc, with: key) {
            self.automerge = AutomergeStore(data: plain)
        } else {
            self.automerge = AutomergeStore()
        }
    }

    // MARK: - Load

    /// Read the current in-memory snapshot. Tasks are filtered to this
    /// project id — a shared file shouldn't contain anyone else's tasks,
    /// but defense-in-depth is cheap.
    func readSnapshot() throws -> Snapshot {
        let shape = try automerge.snapshot()
        guard let project = shape.projects.first(where: { $0.id == projectId }) else {
            throw StoreError.missingProject
        }
        let tasks = shape.tasks.filter { $0.list == projectId }
        return Snapshot(tasks: tasks, project: project)
    }

    // MARK: - Save

    /// Upsert the snapshot into the live doc and write the encrypted
    /// envelope to disk atomically. `deletedTaskIds` produce real
    /// Automerge tombstones so deletions propagate.
    func save(_ snapshot: Snapshot, deletedTaskIds: Set<String> = []) throws {
        // Sanity: every task in a shared project must be listed under
        // that project. Anything else is a caller bug.
        for t in snapshot.tasks where t.list != projectId {
            assertionFailure("PerProjectStore: task \(t.id) has list=\(t.list), expected \(projectId)")
        }
        try automerge.upsertProject(snapshot.project)
        try automerge.upsertTasks(snapshot.tasks)
        for id in deletedTaskIds { try automerge.deleteTask(id) }

        let plain = automerge.save()
        let envelope = try CryptoBox.seal(plain, with: key)
        try writeAtomically(envelope)
    }

    // MARK: - Merge

    /// Decrypt `remoteEnvelope` and merge the peer's changes into our
    /// live doc. Used when the file watcher (or a manual sync) reports
    /// that the on-disk bytes changed. Returns true if the merge landed
    /// cleanly; false if decryption failed (wrong key / tamper / not
    /// our envelope format) — caller can then log + ignore.
    @discardableResult
    func merge(encryptedBytes remoteEnvelope: Data) -> Bool {
        guard let plain = try? CryptoBox.open(remoteEnvelope, with: key) else {
            return false
        }
        let other = AutomergeStore(data: plain)
        do {
            try automerge.merge(other)
            return true
        } catch {
            // Live doc poisoned — rebuild from the peer's bytes as the
            // least-bad recovery, mirroring `TaskStorePersistence`'s
            // `rebuildDoc(from:)` semantics.
            self.automerge = AutomergeStore(data: plain)
            return true
        }
    }

    /// Convenience: re-read our own file from disk and merge in. Used
    /// after an external write lands (Dropbox / iCloud file-provider
    /// dropped updated bytes).
    @discardableResult
    func refreshFromDisk() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let bytes = try? Data(contentsOf: fileURL) else {
            return false
        }
        return merge(encryptedBytes: bytes)
    }

    /// Scan the folder for sibling *conflict copies* of this shared
    /// project's file — the sync daemon's best-effort when two devices
    /// write at roughly the same time and it can't pick a winner.
    ///
    /// Shapes we absorb (all with `.automerge.enc` suffix and the
    /// `shared_<id>` prefix):
    ///
    ///     Dropbox:   shared_<id> (iPhone's conflicted copy 2026-04-20).automerge.enc
    ///     iCloud:    shared_<id> 2.automerge.enc
    ///     Syncthing: shared_<id>.sync-conflict-20260420-123456-XXXX.automerge.enc
    ///
    /// Each matching file is decrypted with our key, merged into the
    /// live doc, then removed from disk so the next scan is quiet.
    /// Files we can't decrypt (wrong key, tamper, unrelated bytes)
    /// are left alone — they aren't ours.
    ///
    /// Returns the number of conflict copies successfully absorbed.
    @discardableResult
    func ingestConflictCopies() -> Int {
        let folder = fileURL.deletingLastPathComponent()
        let canonical = fileURL.lastPathComponent
        let stem = "shared_\(projectId)"
        let suffix = ".automerge.enc"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return 0
        }

        var absorbed = 0
        for entry in entries {
            guard entry != canonical,
                  entry.hasPrefix(stem),
                  entry.hasSuffix(suffix) else { continue }
            // Require a non-word separator after the id so that, e.g.,
            // `shared_p_abc_extra.automerge.enc` (a different project
            // whose id starts with ours) isn't mistakenly absorbed.
            let middle = entry.dropFirst(stem.count).dropLast(suffix.count)
            guard let first = middle.first,
                  !first.isLetter && !first.isNumber && first != "_" else { continue }

            let url = folder.appendingPathComponent(entry)
            guard let bytes = try? Data(contentsOf: url) else { continue }

            if merge(encryptedBytes: bytes) {
                // Only delete after a successful merge — never clobber
                // a file we couldn't actually absorb.
                try? FileManager.default.removeItem(at: url)
                absorbed += 1
            }
        }
        return absorbed
    }

    // MARK: - Disk I/O helpers

    /// Atomic write via a `.tmp` sibling + rename. Matches the macOS
    /// behaviour of `TaskStorePersistence`; the iOS file-provider
    /// stage-then-copy path integrates later when we wire this into
    /// the persistence layer proper.
    private func writeAtomically(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }

    // MARK: - Filename helpers

    /// Canonical filename for a shared project's encrypted doc. Used
    /// by directory scans (loading all shareds at launch) and by the
    /// future share-link import flow.
    static func filename(for projectId: String) -> String {
        "shared_\(projectId).automerge.enc"
    }

    /// Extract the project id from a shared-file name, or nil if it
    /// doesn't match our naming convention.
    static func projectId(fromFilename name: String) -> String? {
        let prefix = "shared_"
        let suffix = ".automerge.enc"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let id = String(name[start..<end])
        return id.isEmpty ? nil : id
    }
}
