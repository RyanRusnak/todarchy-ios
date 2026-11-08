import Foundation
import CryptoKit
import Automerge

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

    /// The envelope bytes this store has already absorbed — either the
    /// ones it wrote itself or the ones it merged in from disk. Comparing
    /// against it turns a refresh tick where nothing external landed into
    /// a memcmp instead of a ChaCha20 open + Automerge parse + fork + CRDT
    /// merge, which is most of what an idle shared-project tick cost.
    ///
    /// Deliberately *not* updated by `merge(encryptedBytes:)`: conflict
    /// copies arrive through that path and their bytes never become the
    /// canonical file.
    private var lastEnvelopeBytes: Data?

    /// A newly accepted invitation has only a local placeholder until its
    /// first download. Preserve local edits without publishing that stub.
    private var placeholderProject: ProjectItem?

    private var pendingFileURL: URL { fileURL.appendingPathExtension("pending") }

    func setPlaceholderProject(_ project: ProjectItem) {
        if !hasProjectRecord { placeholderProject = project }
    }

    /// A cached HTTP response is not proof that this store received it.
    /// Until a real project record has merged, request the full envelope.
    var needsInitialDownload: Bool { !hasProjectRecord }

    private var hasProjectRecord: Bool {
        (try? automerge.projects().contains { $0.id == projectId }) == true
    }

    /// Heads of the doc the canonical file is known to hold in full.
    /// `persistIfNeeded` writes only when the live doc has moved past it,
    /// which is how relay merges and absorbed conflict copies reach disk
    /// without an idle tick re-sealing an unchanged doc.
    ///
    /// Seeded with the opening heads even when there's no file yet, so a
    /// blank store never writes — and then pushes — an empty doc over a
    /// populated relay copy.
    private var fileHeads: Set<ChangeHash>

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
            self.lastEnvelopeBytes = enc
        } else {
            self.automerge = AutomergeStore()
        }
        self.fileHeads = automerge.heads()
        // Edits made before the first download are durable locally, but
        // never occupy the canonical file that the relay uploads.
        if let pending = try? Data(contentsOf: pendingFileURL) {
            _ = absorb(pending)
        }
    }

    /// The live doc's head change hashes. Cheap — no serialization.
    func heads() -> Set<ChangeHash> {
        automerge.heads()
    }

    // MARK: - Load

    /// Read the current in-memory snapshot. Tasks are filtered to this
    /// project id — a shared file shouldn't contain anyone else's tasks,
    /// but defense-in-depth is cheap.
    func readSnapshot() throws -> Snapshot {
        let shape = try automerge.snapshot()
        guard let project = shape.projects.first(where: { $0.id == projectId }) ?? placeholderProject else {
            throw StoreError.missingProject
        }
        let tasks = shape.tasks.filter { $0.list == projectId }
        return Snapshot(tasks: tasks, project: project)
    }

    // MARK: - Save

    /// Upsert the snapshot into the live doc and write the encrypted
    /// envelope to disk atomically. `deletedTaskIds` produce real
    /// Automerge tombstones so deletions propagate.
    func save(_ snapshot: Snapshot, deletedTaskIds: Set<String> = [],
              seedProject: Bool = true) throws {
        // Sanity: every task in a shared project must be listed under
        // that project. Anything else is a caller bug.
        for t in snapshot.tasks where t.list != projectId {
            assertionFailure("PerProjectStore: task \(t.id) has list=\(t.list), expected \(projectId)")
        }
        if !seedProject && !hasProjectRecord {
            placeholderProject = snapshot.project
        } else if snapshot.project != placeholderProject {
            // A queued UI snapshot may still contain the placeholder after
            // the first download. Never write it over the real metadata.
            try automerge.upsertProject(snapshot.project)
            placeholderProject = nil
        }
        try automerge.upsertTasks(snapshot.tasks)
        for id in deletedTaskIds { try automerge.deleteTask(id) }

        if hasProjectRecord {
            try writeCurrentDoc()
        } else {
            let pending = try CryptoBox.seal(automerge.save(), with: key)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try pending.write(to: pendingFileURL, options: .atomic)
        }
    }

    /// Write the live doc to disk if it holds anything the file doesn't.
    /// Returns true when it wrote.
    ///
    /// For changes that arrive *without* a local edit: a relay pull, or
    /// an absorbed conflict copy (whose sibling file is deleted as soon as
    /// it's merged). Without this both lived only in memory until the user
    /// next edited this project.
    @discardableResult
    func persistIfNeeded() throws -> Bool {
        guard hasProjectRecord, automerge.heads() != fileHeads else { return false }
        try writeCurrentDoc()
        return true
    }

    private func writeCurrentDoc() throws {
        let heads = automerge.heads()
        let plain = automerge.save()
        let envelope = try CryptoBox.seal(plain, with: key)
        try writeAtomically(envelope)
        lastEnvelopeBytes = envelope
        fileHeads = heads
        try? FileManager.default.removeItem(at: pendingFileURL)
    }

    // MARK: - Merge

    /// Decrypt `remoteEnvelope` and merge the peer's changes into our
    /// live doc. Used when the file watcher (or a manual sync) reports
    /// that the on-disk bytes changed. Returns true if the merge landed
    /// cleanly; false if decryption failed (wrong key / tamper / not
    /// our envelope format) — caller can then log + ignore.
    @discardableResult
    func merge(encryptedBytes remoteEnvelope: Data) -> Bool {
        absorb(remoteEnvelope) != nil
    }

    /// Same as `merge(encryptedBytes:)`, but hands back the heads of the
    /// doc that was merged in, or nil when it couldn't be opened.
    ///
    /// The relay pull uses this to tell whether the relay is *behind*: if
    /// our heads differ from the relay doc's after merging it, we hold
    /// changes the relay is missing and owe it a push.
    func mergeReturningRemoteHeads(encryptedBytes remoteEnvelope: Data) -> Set<ChangeHash>? {
        absorb(remoteEnvelope)
    }

    private func absorb(_ remoteEnvelope: Data) -> Set<ChangeHash>? {
        guard let plain = try? CryptoBox.open(remoteEnvelope, with: key) else {
            return nil
        }
        let other = AutomergeStore(data: plain)
        do {
            try automerge.merge(other)
        } catch {
            // Live doc poisoned — rebuild from the peer's bytes as the
            // least-bad recovery, mirroring `TaskStorePersistence`'s
            // `rebuildDoc(from:)` semantics.
            self.automerge = AutomergeStore(data: plain)
        }
        return other.heads()
    }

    /// Convenience: re-read our own file from disk and merge in. Used
    /// after an external write lands (Dropbox / iCloud file-provider
    /// dropped updated bytes).
    ///
    /// Returns true only when the live doc actually moved, so callers can
    /// tell "a peer's edit arrived" from "this was our own write coming
    /// back around". Bytes identical to what we last absorbed short-circuit
    /// before any crypto or Automerge work; a merge that lands but adds
    /// nothing new still records the bytes so the next tick skips them too.
    @discardableResult
    func refreshFromDisk() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let bytes = try? Data(contentsOf: fileURL) else {
            return false
        }
        if bytes == lastEnvelopeBytes { return false }
        let headsBefore = automerge.heads()
        guard let onDiskHeads = absorb(bytes) else { return false }
        lastEnvelopeBytes = bytes
        // The file now holds exactly `onDiskHeads`. If that's behind the
        // live doc, `persistIfNeeded` will write the difference out.
        fileHeads = onDiskHeads
        return automerge.heads() != headsBefore
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
