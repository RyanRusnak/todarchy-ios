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
    private var pendingSnapshot: Snapshot?
    private var pendingTaskDeletes: Set<String> = []
    private var pendingProjectDeletes: Set<String> = []

    var onExternalChange: (() -> Void)?

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

    func load() -> Snapshot? {
        onQueue { try? automerge.snapshot() }
    }

    // MARK: - Save

    /// Debounced save. Pass any tasks/projects whose ids were explicitly
    /// deleted this tick so they produce real CRDT tombstones.
    func scheduleSave(
        _ snapshot: Snapshot,
        deletedTaskIds: Set<String> = [],
        deletedProjectIds: Set<String> = []
    ) {
        // Fire-and-forget onto the serial queue. This is called from the
        // main thread on every keystroke; using queue.sync here would
        // block the UI whenever the queue is busy with a Dropbox
        // read/write — producing the "can't add tasks" freezes.
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = snapshot
            self.pendingTaskDeletes.formUnion(deletedTaskIds)
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
        deletedTaskIds: Set<String> = [],
        deletedProjectIds: Set<String> = []
    ) {
        onQueue {
            pendingSnapshot = snapshot
            pendingTaskDeletes.formUnion(deletedTaskIds)
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

        // 2. Pull in any conflict copies the sync daemon created.
        ingestConflictCopies()

        // 3. Apply our local mutations on top of the merged doc. Each op is
        //    poison-safe: if the doc is poisoned, rebuild from disk and retry.
        let taskDeletes = pendingTaskDeletes
        let projectDeletes = pendingProjectDeletes
        let writeOk = retryOnPoison {
            try automerge.upsertTasks(snap.tasks)
            try automerge.upsertProjects(snap.projects)
            for id in taskDeletes { try automerge.deleteTask(id) }
            for id in projectDeletes { try automerge.deleteProject(id) }
            try writeBytes(automerge.save())
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
    /// on iOS) and as a manual "Refresh" affordance.
    func refreshFromDisk() {
        onQueue {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let bytes = readBytes(from: fileURL) else { return }
            _ = mergeOrRebuild(bytes)
            ingestConflictCopies()
            // Always write back — this resolves conflict copies on disk.
            _ = retryOnPoison { try writeBytes(automerge.save()) }
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
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
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
            let writeOk = retryOnPoison {
                try writeBytes(automerge.save())
            }
            if !writeOk {
                return .init(success: false, taskCount: nil,
                             message: "Sync folder wasn't writable. Try Stop + Pick again.")
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
            if !replaceLocalDoc {
                _ = retryOnPoison { try writeBytes(automerge.save()) }
            }
            startWatching()
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
    }

    deinit { stopWatching() }
}
