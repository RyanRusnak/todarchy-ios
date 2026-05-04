import Foundation
import Automerge

/// On-disk persistence backed by a single Automerge binary document.
///
/// There's no parallel JSON — the .automerge bytes ARE the store. The file can
/// live in Application Support (local-only) or a user-picked sync folder
/// (iCloud Drive, Dropbox, Syncthing, …). Other devices mutate the same file
/// through their own file-sync daemon; we watch it and `merge()` their bytes
/// into our in-memory doc.
///
/// Save semantics: upsert-only. A snapshot passed to `scheduleSave` writes
/// each task/project at its id; it never tombstones a key just because it's
/// absent from the snapshot. Callers register explicit deletions via the
/// `deletedTaskIds` / `deletedProjectIds` sets.
final class TaskStorePersistence {
    static let shared = TaskStorePersistence()

    private(set) var fileURL: URL
    /// Mutable so we can replace the Automerge doc wholesale when it gets
    /// poisoned by a Rust panic — subsequent ops would otherwise fail with
    /// `PoisonError` forever. Recovery: reload a fresh doc from the bytes
    /// currently on disk.
    private var automerge: AutomergeStore
    private let saveDelay: TimeInterval = 0.25
    private var saveWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    /// The ONE serial queue through which every Automerge doc operation
    /// must flow. Automerge's Rust internals panic (PatchLogMismatch)
    /// under concurrent Document construction / merge — our NSRecursiveLock
    /// inside AutomergeStore is not enough because Document init itself
    /// isn't thread-safe in automerge-swift 0.7.2.
    private let queue = DispatchQueue(label: "todarchy.persistence", qos: .userInitiated)
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queueID = ObjectIdentifier(TaskStorePersistence.self)

    /// Run `body` on `queue`. Re-entrant: if we're already on the queue,
    /// execute inline rather than deadlocking with queue.sync.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return try body()
        }
        return try queue.sync { try body() }
    }

    // Pending save state. Accumulated across debounce cycles so a burst of
    // mutations + one delete all end up in the same disk write.
    //
    // `pendingTaskDeletes` is `[taskId: listId]` so flushNow can route
    // each tombstone to the right doc (main vs a shared project's file).
    private var pendingSnapshot: Snapshot?
    private var pendingTaskDeletes: [String: String] = [:]
    private var pendingProjectDeletes: Set<String> = []

    var onExternalChange: (() -> Void)?

    /// Installed by SyncSettings so Persistence can open per-project
    /// encrypted stores for shared projects. `nil` in test setups that
    /// only care about the main doc path.
    var sharedProjectManager: SharedProjectManager?

    /// Currently-loaded PerProjectStores, keyed by project id. Opened
    /// lazily in `refreshSharedStores` when the main doc surfaces an
    /// `isShared` project and we have the key. Persisted across ticks
    /// so we don't re-open + re-decrypt on every save.
    private var sharedStores: [String: PerProjectStore] = [:]

    /// HTTP relay client. `nil` unless the user has picked `.server`
    /// mode. Installed + torn down by `SyncSettings`. When present,
    /// Persistence additionally pulls/pushes the main-doc bytes (and
    /// each shared-project envelope) around local writes.
    var serverClient: ServerSyncClient?

    /// Server-side id for the main doc. Paired with `serverClient`.
    var serverMainDocId: String?

    /// 30-second foreground poll timer. Fires `refreshFromDisk` so the
    /// existing pipeline picks up server changes alongside file
    /// changes. Started by `setFileURL` when the server client is
    /// installed; cancelled otherwise.
    private var serverPollTimer: Timer?

    /// iOS security-scope URL. MUST be the exact URL instance that was
    /// granted scope (from `.fileImporter` or `resolvingBookmarkData`), not
    /// a re-constructed copy — the scope attribute only lives on that
    /// instance. SyncSettings installs this when a folder is chosen or
    /// restored at launch. Used to bracket reads/writes with
    /// startAccessingSecurityScopedResource() on iOS where the file-
    /// provider sandbox (Dropbox / iCloud via Files app) denies writes
    /// outside an active scope.
    var scopedFolderURL: URL?

    /// Run `body` with iOS security scope activated on the sync folder.
    /// No-op on macOS (scope is managed at the app/sandbox level there).
    private func withScopedFolder<T>(_ body: () throws -> T) rethrows -> T {
        #if os(iOS)
        guard let scopeURL = scopedFolderURL else { return try body() }
        let didAccess = scopeURL.startAccessingSecurityScopedResource()
        defer { if didAccess { scopeURL.stopAccessingSecurityScopedResource() } }
        #if DEBUG
        if !didAccess {
            print("todarchy: security scope NOT granted on \(scopeURL.path) — writes will fail with EPERM")
        }
        #endif
        return try body()
        #else
        return try body()
        #endif
    }

    init(fileURL: URL = TaskStorePersistence.defaultFileURL()) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        queue.setSpecific(key: Self.queueKey, value: queueID)
        let data = Self.readBytesStatic(from: fileURL)
        // Construct the Automerge doc and start the file watcher on the
        // queue so every Document op from here on lives on one thread.
        self.automerge = queue.sync { AutomergeStore(data: data) }
        queue.sync { startWatching() }
    }

    nonisolated static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)) ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("todarchy", isDirectory: true)
            .appendingPathComponent("tasks.automerge")
    }

    // MARK: - Load

    /// Returns the UNION of the main doc + all opened shared-project
    /// stores. From the TaskStore's perspective, this one array is all
    /// the tasks across every project, regardless of which file they
    /// physically live in. The `isShared` flag on each project is the
    /// only signal that distinguishes them, and that carries through
    /// because we source the project record from the shared file when
    /// available (it's the authoritative copy).
    func load() -> Snapshot? {
        onQueue {
            guard var snap = try? automerge.snapshot() else { return nil }
            refreshSharedStores(mainProjects: snap.projects)
            for (pid, store) in sharedStores {
                guard let sharedSnap = try? store.readSnapshot() else { continue }
                // Replace tasks for this project with the shared file's
                // copy so a stale entry from the main doc (pre-promotion)
                // doesn't ghost the real state.
                snap.tasks.removeAll { $0.list == pid }
                snap.tasks.append(contentsOf: sharedSnap.tasks)
                // Prefer the shared file's project metadata — it's what
                // collaborators edit, so it's authoritative over the
                // stub in the main doc.
                if let idx = snap.projects.firstIndex(where: { $0.id == pid }) {
                    snap.projects[idx] = sharedSnap.project
                }
            }
            return snap
        }
    }

    /// Open `PerProjectStore`s for any shared project in the main doc
    /// that we have a key for but haven't loaded yet. Close stores for
    /// projects that are no longer shared. Idempotent.
    private func refreshSharedStores(mainProjects: [ProjectItem]) {
        guard let manager = sharedProjectManager else { return }
        let sharedIds = Set(mainProjects.filter { $0.isShared }.map { $0.id })

        // Open new ones.
        for pid in sharedIds where sharedStores[pid] == nil {
            if let store = manager.openStore(for: pid) {
                sharedStores[pid] = store
            }
        }
        // Drop stores whose project is no longer shared / no longer in
        // the main doc.
        for pid in sharedStores.keys where !sharedIds.contains(pid) {
            sharedStores.removeValue(forKey: pid)
        }
    }

    // MARK: - Save

    /// Debounced save. `deletedTaskIds` is `[taskId: listId]` — the
    /// listId lets flushNow route each tombstone to either the main
    /// doc or the matching shared-project file.
    func scheduleSave(
        _ snapshot: Snapshot,
        deletedTaskIds: [String: String] = [:],
        deletedProjectIds: Set<String> = []
    ) {
        // Fire-and-forget onto the serial queue. This is called from the
        // main thread on every keystroke; using queue.sync here would
        // block the UI whenever the queue is busy with a Dropbox
        // read/write — producing the "can't add tasks" freezes.
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = snapshot
            self.pendingTaskDeletes.merge(deletedTaskIds) { _, new in new }
            self.pendingProjectDeletes.formUnion(deletedProjectIds)
            self.saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flushNow()
            }
            self.saveWork = work
            self.queue.asyncAfter(deadline: .now() + self.saveDelay, execute: work)
        }
    }

    /// Synchronously flush whatever's pending + the given snapshot.
    func saveNow(
        _ snapshot: Snapshot,
        deletedTaskIds: [String: String] = [:],
        deletedProjectIds: Set<String> = []
    ) {
        onQueue {
            pendingSnapshot = snapshot
            pendingTaskDeletes.merge(deletedTaskIds) { _, new in new }
            pendingProjectDeletes.formUnion(deletedProjectIds)
            flushNow()
        }
    }

    private func flushNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let snap = pendingSnapshot else { return }

        // 1. Absorb anything the sync daemon dropped onto disk.
        if FileManager.default.fileExists(atPath: fileURL.path),
           let onDisk = readBytes(from: fileURL) {
            _ = mergeOrRebuild(onDisk)
        }

        // 1b. In server mode, pull the latest bytes from the relay and
        //     merge them in. Synchronous on this queue so that the
        //     upcoming write incorporates peer changes from the server.
        pullMainFromServerSync()

        // 2. Pull in any conflict copies the sync daemon created.
        ingestConflictCopies()

        // 3. Refresh shared-store roster against the latest main-doc
        //    project list — promotions done this tick will have flipped
        //    isShared=true on a project, which is our signal to open
        //    its encrypted store.
        refreshSharedStores(mainProjects: snap.projects)

        // 4. Pull peer changes into each shared store before we apply
        //    local mutations, so we're merging into the freshest state.
        //    Also sweep up any conflict copies the sync daemon left
        //    behind — same contract as the main-doc ingestion above
        //    but per-shared-file. In server mode, pull the envelope
        //    bytes from the relay too.
        for (pid, store) in sharedStores {
            _ = store.refreshFromDisk()
            _ = store.ingestConflictCopies()
            pullSharedFromServerSync(projectId: pid, store: store)
        }

        // 5. Split the pending snapshot by destination. A task lives
        //    in a shared store iff its `list` matches an opened shared
        //    project id. Everything else is main-doc.
        let sharedIds = Set(sharedStores.keys)
        let mainTasks = snap.tasks.filter { !sharedIds.contains($0.list) }
        let tasksByShared = Dictionary(grouping: snap.tasks.filter { sharedIds.contains($0.list) },
                                       by: \.list)
        let mainDeletes = pendingTaskDeletes.filter { !sharedIds.contains($0.value) }.map(\.key)
        let deletesByShared = Dictionary(grouping: pendingTaskDeletes.filter { sharedIds.contains($0.value) },
                                         by: \.value)
            .mapValues { Set($0.map(\.key)) }
        let projectDeletes = pendingProjectDeletes

        // 6. Apply main-doc writes. Same poison-safe retry dance.
        //    Capture the bytes actually written so we can mirror them
        //    to the server without re-saving the doc (which would
        //    produce a different-but-equivalent blob every time).
        var mainBytesForServer: Data?
        let writeOk = retryOnPoison {
            try automerge.upsertTasks(mainTasks)
            try automerge.upsertProjects(snap.projects)
            if let contexts = snap.contexts {
                try automerge.writeContexts(contexts)
            }
            for id in mainDeletes { try automerge.deleteTask(id) }
            for id in projectDeletes { try automerge.deleteProject(id) }
            let bytes = automerge.save()
            try writeBytes(bytes)
            mainBytesForServer = bytes
        }

        // 7. Apply shared-store writes. Each store is independent;
        //    failures here don't invalidate main-doc writes.
        for (pid, store) in sharedStores {
            guard let project = snap.projects.first(where: { $0.id == pid }) else { continue }
            let tasks = tasksByShared[pid] ?? []
            let deletes = deletesByShared[pid] ?? []
            do {
                try store.save(.init(tasks: tasks, project: project),
                               deletedTaskIds: deletes)
                pushSharedToServer(projectId: pid, fileURL: store.fileURL)
            } catch {
                #if DEBUG
                print("todarchy: shared-store save failed for \(pid): \(error)")
                #endif
            }
        }

        // 7b. Mirror the main doc to the server. Fire-and-forget so the
        //     persistence queue isn't blocked on the network round-trip.
        if let bytes = mainBytesForServer {
            pushMainToServer(bytes)
        }

        // Drain the pending buffers regardless of write success — leaving
        // them populated would replay on the next tick and likely fail the
        // same way, stuck in a silent-failure loop.
        pendingSnapshot = nil
        pendingTaskDeletes.removeAll()
        pendingProjectDeletes.removeAll()

        // Always refresh the UI. Even on write failure, retryOnPoison left
        // the in-memory doc loaded with the latest disk state, so the UI
        // should show whatever has been synced — and hiding the refresh
        // would only make a transient blip look like "nothing happened".
        _ = writeOk
        DispatchQueue.main.async { [weak self] in
            self?.onExternalChange?()
        }
    }

    // MARK: - Server mirror

    /// Start an async pull of the main doc from the relay. When bytes
    /// come back we hop back to `queue` to merge them into the live doc
    /// and notify the UI. Non-blocking — the persistence queue keeps
    /// processing user mutations while the network round-trip is in
    /// flight. Safe to call on any thread; no-op outside server mode.
    ///
    /// The user's "always overwrite the server" semantics mean we
    /// don't need to *wait* for a pre-write merge: peer changes are
    /// picked up on the next poll / refresh and will converge via
    /// Automerge, since the CRDT makes every pull idempotent.
    private func pullMainFromServerSync() {
        guard let client = serverClient, let id = serverMainDocId else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                guard let result = try await client.get(id) else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    _ = self.mergeOrRebuild(result.0)
                    DispatchQueue.main.async {
                        SyncSettings.shared.markServerHealth(.ok)
                        self.onExternalChange?()
                    }
                }
            } catch {
                await MainActor.run {
                    SyncSettings.shared.markServerHealth(.failing(error.localizedDescription))
                }
            }
        }
    }

    /// Async pull of a shared-project envelope. Mirror of
    /// `pullMainFromServerSync`. Merging hops back onto `queue` so all
    /// Automerge operations stay single-threaded.
    private func pullSharedFromServerSync(projectId: String, store: PerProjectStore) {
        guard let client = serverClient else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                guard let result = try await client.get(projectId) else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    _ = store.merge(encryptedBytes: result.0)
                    DispatchQueue.main.async {
                        self.onExternalChange?()
                    }
                }
            } catch {
                #if DEBUG
                print("todarchy: server GET \(projectId) failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Push the given main-doc bytes to the relay. Unconditional PUT —
    /// the app is local-first, so we never surrender a write on 412.
    /// Fire-and-forget: we do not block the persistence queue on the
    /// network round-trip. Errors surface on `SyncSettings.serverHealth`.
    private func pushMainToServer(_ bytes: Data) {
        guard let client = serverClient, let id = serverMainDocId else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await client.put(id, bytes)
                await MainActor.run {
                    SyncSettings.shared.markServerHealth(.ok)
                }
            } catch {
                await MainActor.run {
                    SyncSettings.shared.markServerHealth(.failing(error.localizedDescription))
                }
            }
        }
    }

    /// Push a shared-project envelope (read from its local cache file)
    /// to the relay. Same unconditional semantics as `pushMainToServer`.
    private func pushSharedToServer(projectId: String, fileURL: URL) {
        guard let client = serverClient else { return }
        guard let bytes = try? Data(contentsOf: fileURL) else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await client.put(projectId, bytes)
            } catch {
                #if DEBUG
                print("todarchy: server PUT \(projectId) failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Start the foreground 30s poll that pulls from the server at a
    /// steady cadence while the app is active. Idempotent; safe to call
    /// whenever the server client is installed.
    private func startServerPollTimer() {
        stopServerPollTimer()
        guard serverClient != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshFromDisk()
            }
            // Keep firing while the run loop is busy with UI events.
            RunLoop.main.add(t, forMode: .common)
            self.serverPollTimer = t
        }
    }

    private func stopServerPollTimer() {
        serverPollTimer?.invalidate()
        serverPollTimer = nil
    }

    /// Scan the canonical file's directory for sibling `*.automerge` files
    /// (conflict copies). Merge each one into the live doc, then delete.
    ///
    /// Conflict filename shapes we've seen in the wild:
    ///   Dropbox:   `tasks (iPhone's conflicted copy 2026-04-20).automerge`
    ///   iCloud:    `tasks 2.automerge`
    ///   Syncthing: `tasks.sync-conflict-20260420-123456-XXXX.automerge`
    /// All have a `.automerge` suffix and start with our canonical stem.
    private func ingestConflictCopies() {
        let dir = fileURL.deletingLastPathComponent()
        let canonical = fileURL.lastPathComponent
        let stem = (canonical as NSString).deletingPathExtension
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries where entry != canonical
                                && entry.hasSuffix(".automerge")
                                && entry.hasPrefix(stem) {
            let url = dir.appendingPathComponent(entry)
            if let bytes = readBytes(from: url) {
                let other = AutomergeStore(data: bytes)
                try? automerge.merge(other)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Force a re-read of the canonical file and merge into the live doc.
    /// Called on iOS when the app returns to the foreground (since
    /// DispatchSourceFileSystemObject doesn't fire for daemon-driven changes
    /// on iOS), as a manual "Refresh" affordance, and by the server poll
    /// timer every 30 seconds when in server mode.
    func refreshFromDisk() {
        onQueue {
            // Pull from the server first so disk + server state reconcile
            // in one merge pass.
            pullMainFromServerSync()
            if FileManager.default.fileExists(atPath: fileURL.path),
               let bytes = readBytes(from: fileURL) {
                _ = mergeOrRebuild(bytes)
            }
            ingestConflictCopies()

            // Now that the main doc is current, open any newly shared
            // projects and pull each store's envelope bytes from both
            // disk and the server.
            if let snap = try? automerge.snapshot() {
                refreshSharedStores(mainProjects: snap.projects)
            }
            for (pid, store) in sharedStores {
                _ = store.refreshFromDisk()
                _ = store.ingestConflictCopies()
                pullSharedFromServerSync(projectId: pid, store: store)
            }

            // Always write back — this resolves conflict copies on disk.
            var mainBytesForServer: Data?
            _ = retryOnPoison {
                let b = automerge.save()
                try writeBytes(b)
                mainBytesForServer = b
            }
            if let b = mainBytesForServer {
                pushMainToServer(b)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onExternalChange?()
            }
        }
    }

    /// Replace the live Automerge doc with a fresh one loaded from `bytes`.
    /// Used for poison recovery — the old doc's internal mutex may have
    /// been poisoned by a Rust panic in Automerge, and the only way to
    /// keep the app alive is to drop it.
    private func rebuildDoc(from bytes: Data) {
        self.automerge = AutomergeStore(data: bytes)
    }

    /// Attempt a merge. If it throws (e.g. PoisonError from a prior panic
    /// stuck on the doc), rebuild the live doc from the incoming bytes and
    /// return the resulting state.
    private func mergeOrRebuild(_ bytes: Data) -> (ok: Bool, errorMessage: String?) {
        let other = AutomergeStore(data: bytes)
        do {
            try automerge.merge(other)
            return (true, nil)
        } catch {
            // The live doc is poisoned. The on-disk bytes are our best
            // surviving snapshot. Rebuild from them and move on.
            rebuildDoc(from: bytes)
            return (true, "merge was unrecoverable; rebuilt from disk")
        }
    }

    /// Run an Automerge op. If it throws — most commonly PoisonError after
    /// a prior Rust panic left the doc's internal mutex stuck — rebuild the
    /// live doc from the latest on-disk bytes and retry ONCE. Returns true
    /// if the op ultimately succeeded.
    ///
    /// This is the last line of defense: we don't want one poisoned mutex
    /// to take down every subsequent save for the life of the process, and
    /// we don't want raw `PoisonError {...}` strings leaking into the UI.
    @discardableResult
    private func retryOnPoison(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            // Reload from disk so we still have the latest synced state.
            if FileManager.default.fileExists(atPath: fileURL.path),
               let bytes = readBytes(from: fileURL) {
                rebuildDoc(from: bytes)
            } else {
                // No disk to fall back to — start fresh. Our caller still
                // holds the pending snapshot, so on the retry we'll write
                // it out.
                self.automerge = AutomergeStore(data: nil)
            }
            do {
                try body()
                return true
            } catch {
                #if DEBUG
                print("todarchy: op failed even after rebuild: \(error)")
                #endif
                return false
            }
        }
    }

    /// User-facing sync trigger. Pushes any pending saves first (so the
    /// bytes on disk match our in-memory state), then coordinated-reads
    /// the file, merges, and writes back. Posts `onExternalChange` and
    /// returns the count of tasks present after the sync for UI feedback.
    @discardableResult
    func syncNow() -> SyncResult {
        onQueue {
            if pendingSnapshot != nil {
                flushNow()
            }
            // Server-mode pull before we inspect the local file — if the
            // user just enabled server mode we may not have any local
            // file yet, but remote state should still come through.
            pullMainFromServerSync()
            for (pid, store) in sharedStores {
                _ = store.refreshFromDisk()
                pullSharedFromServerSync(projectId: pid, store: store)
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                // With server mode active, we may have merged remote bytes
                // but have no local file yet — write one now so subsequent
                // reads find something.
                if serverClient != nil {
                    var bytesForServer: Data?
                    let wrote = retryOnPoison {
                        let b = automerge.save()
                        try writeBytes(b)
                        bytesForServer = b
                    }
                    if wrote, let b = bytesForServer {
                        pushMainToServer(b)
                        let count = (try? automerge.snapshot().tasks.count) ?? 0
                        DispatchQueue.main.async { [weak self] in
                            self?.onExternalChange?()
                        }
                        return .init(success: true, taskCount: count, message: nil)
                    }
                }
                return .init(success: false, taskCount: nil,
                             message: "Sync file doesn't exist yet at \(fileURL.lastPathComponent)")
            }
            // iOS file-providers (Dropbox/iCloud via Files app) sometimes
            // fail the first read while they finish materializing the
            // latest remote bytes. Retry with small backoff before giving
            // up so users aren't told "sync failed" for a 200ms blip.
            var bytes: Data?
            for delay in [0, 500_000, 1_500_000] {  // 0ms, 500ms, 1500ms
                if delay > 0 { usleep(useconds_t(delay)) }
                if let b = readBytes(from: fileURL) {
                    bytes = b
                    break
                }
            }
            guard let bytes else {
                return .init(success: false, taskCount: nil,
                             message: "Couldn't read sync file after 2s — the file provider may still be downloading. Try again in a moment.")
            }
            _ = mergeOrRebuild(bytes)
            ingestConflictCopies()
            var bytesForServer: Data?
            let writeOk = retryOnPoison {
                let b = automerge.save()
                try writeBytes(b)
                bytesForServer = b
            }
            if !writeOk {
                return .init(success: false, taskCount: nil,
                             message: "Sync folder wasn't writable. Try Stop + Pick again.")
            }
            if let b = bytesForServer {
                pushMainToServer(b)
            }
            let count = (try? automerge.snapshot().tasks.count) ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.onExternalChange?()
            }
            return .init(success: true, taskCount: count, message: nil)
        }
    }

    struct SyncResult: Equatable {
        let success: Bool
        let taskCount: Int?
        let message: String?
    }

    /// Atomic write: .tmp sibling + rename, wrapped in NSFileCoordinator so
    /// iOS file-provider URLs (Dropbox / iCloud Drive via the Files app)
    /// actually propagate the write to the provider extension. Without this,
    /// writes on iOS land in a sandboxed path that never reaches the
    /// upstream sync daemon.
    private func writeBytes(_ data: Data) throws {
        try withScopedFolder {
            try writeBytesUnscoped(data)
        }
    }

    private func writeBytesUnscoped(_ data: Data) throws {
        #if os(iOS)
        // iOS file-providers (Dropbox/iCloud via Files app) reject direct
        // `Data.write(to:)` into the provider path with EPERM even when
        // security scope is active. The supported write path is:
        //   1. Write bytes into the app's own sandbox (always writable).
        //   2. Use NSFileCoordinator + FileManager.replaceItemAt, which
        //      goes through the provider extension's copy/replace API.
        let sandboxDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stagingURL = sandboxDir
            .appendingPathComponent("todarchy-staging-\(UUID().uuidString).automerge")
        try data.write(to: stagingURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let coord = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coord.coordinate(writingItemAt: fileURL,
                         options: [.forReplacing],
                         error: &coordError) { actualURL in
            do {
                if FileManager.default.fileExists(atPath: actualURL.path) {
                    _ = try FileManager.default.replaceItemAt(actualURL, withItemAt: stagingURL)
                } else {
                    try FileManager.default.copyItem(at: stagingURL, to: actualURL)
                }
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
        #else
        let coord = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coord.coordinate(writingItemAt: fileURL,
                         options: [.forReplacing],
                         error: &coordError) { actualURL in
            do {
                let tempURL = actualURL.appendingPathExtension("tmp")
                try data.write(to: tempURL, options: .atomic)
                if FileManager.default.fileExists(atPath: actualURL.path) {
                    _ = try FileManager.default.replaceItemAt(actualURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: actualURL)
                }
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
        #endif
    }

    /// Coordinated read — pairs with `writeBytes`. On iOS, blocks until the
    /// file provider downloads any pending changes; without this, we see
    /// stale placeholders.
    private func readBytes(from url: URL) -> Data? {
        withScopedFolder {
            Self.readBytesStatic(from: url)
        }
    }

    /// Same as `readBytes` but callable from `init` before `self` is fully
    /// initialized.
    static func readBytesStatic(from url: URL) -> Data? {
        let coord = NSFileCoordinator()
        var result: Data?
        var coordError: NSError?
        coord.coordinate(readingItemAt: url,
                         options: [.resolvesSymbolicLink],
                         error: &coordError) { actualURL in
            result = try? Data(contentsOf: actualURL)
        }
        // Fall back to a direct read if coordination refused or produced no
        // bytes — the file coordinator sometimes times out or can't reach a
        // file-provider lock on macOS test bursts, and for local paths a
        // plain read is functionally equivalent.
        if result == nil {
            result = try? Data(contentsOf: url)
        }
        return result
    }

    // MARK: - External changes (local filesystem)

    private func startWatching() {
        stopWatching()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // Go through the coordinated write so iOS file-provider paths
            // don't reject a .tmp sibling we're not authorized to create.
            _ = try? writeBytes(automerge.save())
        }
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleExternalEvent()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func handleExternalEvent() {
        // Already on `queue` because the DispatchSource was created with it.
        if let bytes = readBytes(from: fileURL) {
            _ = mergeOrRebuild(bytes)
            ingestConflictCopies()
            DispatchQueue.main.async { [weak self] in
                self?.onExternalChange?()
            }
        }
        // Re-arm the watcher on the same queue we're on.
        startWatching()
    }

    // MARK: - Re-point the sync folder

    /// Switch to a different file URL. If `replaceLocalDoc` is true (the
    /// startup path), adopt the target's bytes verbatim — no merge. This
    /// avoids the PatchLogMismatch panics that fire when two docs with
    /// disjoint change histories are merged before any user interaction.
    /// For user-initiated folder changes from the settings UI, pass false
    /// so their local unsynced edits are preserved via a real merge.
    func setFileURL(_ newURL: URL, replaceLocalDoc: Bool = false) throws {
        try onQueue {
            stopWatching()
            try FileManager.default.createDirectory(
                at: newURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: newURL.path),
               let targetBytes = readBytes(from: newURL) {
                if replaceLocalDoc {
                    rebuildDoc(from: targetBytes)
                } else {
                    _ = mergeOrRebuild(targetBytes)
                    ingestConflictCopies()
                }
            }
            self.fileURL = newURL
            var bytesForServer: Data?
            if !replaceLocalDoc {
                _ = retryOnPoison {
                    let b = automerge.save()
                    try writeBytes(b)
                    bytesForServer = b
                }
            }
            // If we just switched into a server-backed mode, mirror our
            // current local bytes to the relay so the remote catches up
            // to the state we're carrying forward.
            if !replaceLocalDoc, let b = bytesForServer {
                pushMainToServer(b)
            }
            startWatching()
            // Keep the poll timer in sync with the server-client presence.
            if serverClient != nil {
                startServerPollTimer()
            } else {
                stopServerPollTimer()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onExternalChange?()
            }
        }
    }

    // MARK: - Snapshot type

    struct Snapshot: Codable, Equatable {
        var schema: Int = 1
        var tasks: [TaskItem]
        var projects: [ProjectItem]
        /// User's context list. Optional in the wire format so older
        /// snapshots without the field decode cleanly; missing/empty
        /// means "fall back to the built-in seed set" at the call site.
        var contexts: [TaskContext]? = nil
    }

    deinit {
        stopWatching()
        serverPollTimer?.invalidate()
    }
}
