import Foundation
import Automerge
import CryptoKit

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
final class TaskStorePersistence: @unchecked Sendable {
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
    private var pendingDoneAtClears: Set<String> = []

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

    /// 10-second foreground poll timer. Fires `refreshFromDisk` so the
    /// existing pipeline picks up server changes alongside file
    /// changes. Started by `setFileURL` when the server client is
    /// installed; cancelled otherwise.
    private var serverPollTimer: Timer?

    /// Key material for sealing the main doc on its way to the relay,
    /// paired with the Argon2 salt it was derived from — the salt rides
    /// in the envelope's clear header so another device holding only the
    /// passphrase can re-derive.
    struct RelayKey {
        let key: SymmetricKey
        let salt: Data
    }

    private let relayKeyLock = NSLock()
    private var _relayKey: RelayKey?

    /// Installed by `SyncSettings` whenever the master key unlocks, locks,
    /// or its salt changes. Unlike everything else here it is *not*
    /// queue-confined — it's written from the MainActor and read from the
    /// persistence queue — so it carries its own lock.
    var relayKey: RelayKey? {
        get { relayKeyLock.lock(); defer { relayKeyLock.unlock() }; return _relayKey }
        set { relayKeyLock.lock(); _relayKey = newValue; relayKeyLock.unlock() }
    }

    /// Sticky: set once we've seen a sealed envelope come back from the
    /// relay. From then on a plaintext PUT would be a downgrade that
    /// silently undoes encryption for every other device, so we refuse to
    /// push at all while the key is unavailable. Persisted so the refusal
    /// survives a relaunch with a locked keychain.
    /// Internal rather than private so tests can arm and reset it; it's
    /// process-wide state (one relay doc per install), not per-instance.
    var relayIsEncrypted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.relayEncryptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.relayEncryptedKey) }
    }
    private static let relayEncryptedKey = "todarchy.sync.relayEncrypted"

    /// Whether we've completed a GET against the relay this launch, so we
    /// know whether it's holding ciphertext. Until then a plaintext PUT
    /// would be a guess — and on a locked device that first guess is
    /// exactly the downgrade `relayIsEncrypted` exists to prevent, fired
    /// before the flag has had a chance to arm. Queue-confined; per-launch
    /// rather than persisted, so a format change is always re-observed.
    private var relayProbed = false

    /// True while a `ServerPull` batch is awaiting the network. Queue-
    /// confined. Coalesces the 10 s poll: if a relay round-trip outlives
    /// its tick, the next tick does its local disk work and skips the
    /// network rather than stacking a second batch on top.
    private var pullInFlight = false

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
        deletedProjectIds: Set<String> = [],
        doneAtClears: Set<String> = []
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
            self.pendingDoneAtClears.formUnion(doneAtClears)
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
        deletedProjectIds: Set<String> = [],
        doneAtClears: Set<String> = []
    ) {
        onQueue {
            pendingSnapshot = snapshot
            pendingTaskDeletes.merge(deletedTaskIds) { _, new in new }
            pendingProjectDeletes.formUnion(deletedProjectIds)
            pendingDoneAtClears.formUnion(doneAtClears)
            flushNow()
        }
    }

    // MARK: - Share-keys publication

    /// Publish a `(projectId, key)` into the main doc's `shareKeys.cipher`
    /// so the user's other devices learn the key via main-doc sync,
    /// then flush to disk and the server. Called from `TaskStore` right
    /// after `SharedProjectManager.createShared` or `accept` succeeds.
    /// Caller must pass the unlocked master key value — typically read
    /// from `MasterKey.shared.currentKey` on the MainActor before
    /// invoking this.
    func publishShareKey(projectId: String,
                         key: SymmetricKey,
                         masterKey: SymmetricKey) throws {
        try onQueue {
            try ShareKeysSync.publish(projectId: projectId,
                                      key: key,
                                      masterKey: masterKey,
                                      store: automerge)
            try persistShareKeysMutation()
        }
    }

    /// Inverse of `publishShareKey` — for the "leave shared project"
    /// path. The encrypted envelope on the relay is left intact; only
    /// this user's reference to the key is dropped from their main doc.
    func unpublishShareKey(projectId: String, masterKey: SymmetricKey) throws {
        try onQueue {
            try ShareKeysSync.unpublish(projectId: projectId,
                                        masterKey: masterKey,
                                        store: automerge)
            try persistShareKeysMutation()
        }
    }

    /// True if the main doc carries a `shareKeys.salt`. Lets the
    /// passphrase-setup UI decide between "create new" and "enter
    /// existing" mode without reaching into AutomergeStore.
    /// Thread-safe (AutomergeStore has its own lock).
    var hasShareKeysSalt: Bool {
        (try? automerge.readShareKeysSalt()) != nil
    }

    /// Rotate the user's passphrase. Generates a new salt, derives a
    /// new master key, re-encrypts the existing shareKeys cipher.
    /// Other devices detect the salt change and prompt for the new
    /// passphrase.
    @MainActor
    func rotatePassphrase(_ newPassphrase: String) async throws {
        try await ShareKeysSync.shared.rotatePassphrase(newPassphrase, store: automerge)
        try onQueue {
            try persistShareKeysMutation()
        }
    }

    /// Wire `ShareKeysSync.setupPassphrase` to the live AutomergeStore
    /// and flush the resulting `shareKeys.salt` (and any decrypted
    /// keys imported) to disk + server. Called by the passphrase
    /// setup sheet in Settings.
    ///
    /// Throws:
    ///   - `ShareKeysSync.Error.wrongPassphrase` when the doc already
    ///     has a sealed cipher and `passphrase` doesn't open it
    ///   - underlying keychain / disk errors on save
    @MainActor
    func setupPassphrase(_ passphrase: String) async throws {
        // The setupPassphrase call writes salt to the in-memory doc
        // (and may import keys into the keychain on a second-device
        // join). Both are MainActor-safe because AutomergeStore has
        // its own internal lock.
        try await ShareKeysSync.shared.setupPassphrase(passphrase, store: automerge)

        // Migrate any existing keychain keys into the doc cipher.
        // This is the path for existing TestFlight testers whose
        // share keys live only in the local keychain — after first
        // passphrase setup, those keys get published to main doc so
        // their other devices auto-learn them. Idempotent (no-op
        // when the cipher already contains the keys).
        if let masterK = MasterKey.shared.currentKey {
            _ = try? ShareKeysSync.migrateLocalKeys(
                keyStore: ShareKeysSync.shared.keyStore,
                masterKey: masterK,
                store: automerge
            )
        }

        // Flush salt (+ migrated cipher) to disk and push to server
        // so the user's other devices can derive the same master key
        // and read the keys we just migrated.
        try onQueue {
            try persistShareKeysMutation()
        }
    }

    /// After a main-doc merge (disk read, server pull, etc.) call
    /// `ShareKeysSync.adoptFromDoc` so any keys peers published get
    /// imported into the local keychain. Hops to the MainActor
    /// because adopt touches `MasterKey` state. Fire-and-forget — the
    /// next merge tick will retry on transient failure.
    private func adoptShareKeysFromDoc() {
        let store = automerge
        Task { @MainActor in
            do {
                _ = try ShareKeysSync.shared.adoptFromDoc(store)
            } catch {
                #if DEBUG
                print("todarchy: adoptShareKeysFromDoc failed: \(error)")
                #endif
            }
        }
    }

    /// Save the doc to disk and push to the server. Used as the
    /// commit step after a `publishShareKey` / `unpublishShareKey`.
    /// Must be called from the persistence queue.
    private func persistShareKeysMutation() throws {
        var mainBytesForServer: Data?
        let ok = retryOnPoison {
            let bytes = automerge.save()
            try writeBytes(bytes)
            mainBytesForServer = bytes
        }
        guard ok else { return }
        if let bytes = mainBytesForServer {
            pushMainToServer(bytes)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onExternalChange?()
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

        // 1b. No relay pull here, on purpose. This is the debounced
        //     save path — it runs while the user is typing — and awaiting
        //     a round-trip with the serial queue held is precisely what
        //     froze the UI on bad service. The relay's copy is merged by
        //     `applyRefresh` on the 10 s poll and by `syncNow`. Nothing is
        //     lost by not merging first: PUT is unconditional ("local
        //     always wins"), so a push that races a peer is reconciled on
        //     the next tick — every peer re-pushes its own doc each poll,
        //     and Automerge makes the re-merge convergent, not lossy.

        // 2. Pull in any conflict copies the sync daemon created.
        ingestConflictCopies()

        // 2b. Adopt any new share keys peers published into the main
        //     doc since we last synced. Reads `shareKeys.cipher`,
        //     decrypts with the cached master key, and writes any
        //     newly-known keys into the local keychain. Hops to the
        //     MainActor because it touches `MasterKey`.
        adoptShareKeysFromDoc()

        // 3. Refresh shared-store roster against the latest main-doc
        //    project list — promotions done this tick will have flipped
        //    isShared=true on a project, which is our signal to open
        //    its encrypted store.
        refreshSharedStores(mainProjects: snap.projects)

        // 4. Pull peer changes into each shared store before we apply
        //    local mutations, so we're merging into the freshest state.
        //    Also sweep up any conflict copies the sync daemon left
        //    behind — same contract as the main-doc ingestion above
        //    but per-shared-file. Relay envelopes are pulled by the poll,
        //    not here — see 1b.
        for (_, store) in sharedStores {
            _ = store.refreshFromDisk()
            _ = store.ingestConflictCopies()
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
            if let retired = snap.retiredContexts {
                try automerge.writeRetiredContexts(retired)
            }
            for id in mainDeletes { try automerge.deleteTask(id) }
            for id in projectDeletes { try automerge.deleteProject(id) }
            for id in pendingDoneAtClears { try? automerge.clearDoneAt(id) }
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
        pendingDoneAtClears.removeAll()

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

    /// Bytes fetched from the relay in one batch, gathered **off** the
    /// persistence queue and merged onto it by `applyPull`.
    ///
    /// Splitting the pull in two like this is load-bearing. `queue` is
    /// serial and main-thread reads go through it (`load()` -> `onQueue`
    /// -> `queue.sync`), so whatever the queue is busy with back-pressures
    /// onto the UI. The pull used to await its round-trip *while holding
    /// the queue*, which froze the app for the length of that wait x
    /// (1 + sharedStores.count) whenever the relay was slow — the
    /// "spontaneously hangs on bad service" report. Nothing in the fetch
    /// path touches queue-confined state, so it can be awaited from any
    /// thread; the queue is only taken for the CPU-bound Automerge merge.
    private struct ServerPull {
        /// True when a round-trip was actually attempted, i.e. server mode
        /// is on. Health / diagnostics are only updated when it is.
        var attempted: Bool = false
        var mainBytes: Data? = nil
        var sharedBytes: [String: Data] = [:]
        /// `localizedDescription` of a failed main-doc GET, if any. Kept as
        /// a string rather than an `Error` so the value stays Sendable.
        var errorMessage: String? = nil
    }

    /// Everything a pull batch needs, captured on `queue` so the network
    /// side never reads mutable persistence state.
    private struct PullRequest: Sendable {
        let client: ServerSyncClient
        let mainDocId: String?
        let sharedIds: [String]
    }

    /// Round-trip budget for one batch. Same 5 s the old semaphore-based
    /// pull allowed; URLSession's own 30 s request timeout is far too long
    /// to leave the 10 s poll cadence waiting on.
    private static let pullTimeout: TimeInterval = 5

    /// Snapshot the inputs for a pull. Queue-confined — reads
    /// `serverClient` / `serverMainDocId` / `sharedStores`. `nil` outside
    /// server mode.
    ///
    /// Shared ids come from the *opened* stores, so a project that only
    /// becomes shared later in this same tick first pulls on the next one.
    /// That's a <=10 s delay on a freshly accepted invite, and its local
    /// cache file is still read in the meantime.
    private func makePullRequest() -> PullRequest? {
        guard let client = serverClient else { return nil }
        return PullRequest(client: client,
                           mainDocId: serverMainDocId,
                           sharedIds: Array(sharedStores.keys))
    }

    /// Run the GETs for one batch — main doc and shared envelopes in
    /// parallel. Pure network, no `self`: safe to await from anywhere.
    private static func fetch(_ req: PullRequest) async -> ServerPull {
        let work: @Sendable () async -> ServerPull = {
            var pull = ServerPull()
            pull.attempted = true
            // Tuple is (sharedProjectId | nil for the main doc, bytes, failure).
            await withTaskGroup(of: (String?, Data?, String?).self) { group in
                if let mainDocId = req.mainDocId {
                    group.addTask {
                        do { return (nil, try await req.client.get(mainDocId)?.0, nil) }
                        catch { return (nil, nil, error.localizedDescription) }
                    }
                }
                for pid in req.sharedIds {
                    group.addTask {
                        do { return (pid, try await req.client.get(pid)?.0, nil) }
                        catch { return (pid, nil, error.localizedDescription) }
                    }
                }
                for await (pid, bytes, failure) in group {
                    guard let pid else {
                        // Main doc: a nil `bytes` with no failure is a 304.
                        pull.mainBytes = bytes
                        pull.errorMessage = failure
                        continue
                    }
                    if let bytes { pull.sharedBytes[pid] = bytes }
                    #if DEBUG
                    if let failure { print("todarchy: server GET \(pid) failed: \(failure)") }
                    #endif
                }
            }
            return pull
        }

        // Race the batch against the deadline so one wedged connection
        // can't hold the poll cadence hostage.
        return await withTaskGroup(of: ServerPull?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.pullTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ServerPull(
                attempted: true,
                errorMessage: "Server didn't respond within \(Int(Self.pullTimeout))s"
            )
        }
    }

    // MARK: - Relay payload encryption

    /// Seal `bytes` for the relay, or return them unchanged when this
    /// user has no passphrase set up. Returns `nil` to mean "don't push
    /// at all".
    ///
    /// Only the relay copy is encrypted. The local `tasks.automerge` stays
    /// plaintext: it's already behind FileVault and the app sandbox, and
    /// the MCP server and the `todokase` CLI both read it without a key.
    /// The relay is the untrusted party here, not the disk.
    private func sealForRelay(_ bytes: Data) -> Data? {
        guard let relay = relayKey else {
            if relayIsEncrypted {
                // Refusing beats downgrading: pushing plaintext here would
                // strip encryption for every other device on this doc.
                reportServerHealth(.failing(
                    "Relay data is encrypted but the passphrase is locked on this device — enter it to resume syncing."
                ))
                return nil
            }
            guard relayProbed else {
                // Haven't read the relay yet this launch, so we don't know
                // whether it's encrypted. Say nothing and wait: the poll
                // will probe within ~10 s and push then. Not a failure
                // state, so the health indicator stays as it was.
                return nil
            }
            // No passphrase has ever been set, and the relay is in the
            // clear too. Keep syncing rather than silently stranding the
            // user; `SyncSettings` surfaces this so it isn't a quiet
            // fail-open.
            return bytes
        }
        do {
            let sealed = try CryptoBox.seal(bytes, with: relay.key, salt: relay.salt)
            relayIsEncrypted = true
            return sealed
        } catch {
            reportServerHealth(.failing("Couldn't encrypt for the relay: \(error.localizedDescription)"))
            return nil
        }
    }

    /// What came back from the relay.
    private enum RelayPayload {
        /// Plaintext Automerge bytes, ready to merge.
        case plain(Data)
        /// A sealed envelope we can't open — no key, or the wrong one.
        /// Carries the v2 salt when present so the UI can prompt for the
        /// passphrase and derive against it.
        case locked(salt: Data?)
        /// Neither an envelope nor a parseable Automerge doc.
        case unreadable
    }

    /// Interpret bytes fetched from the relay, tolerating the pre-
    /// encryption format. **Must run on `queue`.**
    private func decodeRelayPayload(_ bytes: Data) -> RelayPayload {
        guard CryptoBox.isEnvelope(bytes) else {
            // Legacy plaintext, written by a build from before relay
            // encryption. Merge it; the write-back at the end of this
            // cycle re-uploads the same content sealed.
            return AutomergeStore.isDocument(bytes) ? .plain(bytes) : .unreadable
        }
        // Seeing ciphertext is what arms the no-downgrade rule, whether or
        // not we can actually open it.
        relayIsEncrypted = true
        guard let relay = relayKey,
              let plain = try? CryptoBox.open(bytes, with: relay.key) else {
            return .locked(salt: CryptoBox.salt(in: bytes))
        }
        return AutomergeStore.isDocument(plain) ? .plain(plain) : .unreadable
    }

    private func reportServerHealth(_ health: SyncSettings.ServerHealth) {
        DispatchQueue.main.async {
            SyncSettings.shared.markServerHealth(health)
        }
    }

    /// Merge a completed batch into the live docs and refresh the sync
    /// health indicators. **Must run on `queue`.** Returns true if any
    /// bytes were actually merged.
    @discardableResult
    private func applyPull(_ pull: ServerPull) -> Bool {
        var merged = false
        var blocked: String?
        if let bytes = pull.mainBytes {
            switch decodeRelayPayload(bytes) {
            case .plain(let plain):
                _ = mergeOrRebuild(plain)
                merged = true
            case .locked(let salt):
                if let salt {
                    DispatchQueue.main.async {
                        SyncSettings.shared.noteRelayEnvelopeSalt(salt)
                    }
                }
                blocked = "Relay data is encrypted — enter your passphrase to sync this device."
            case .unreadable:
                blocked = "The relay returned bytes this build can't read."
            }
        }
        // Shared-project envelopes are already sealed under their own
        // per-project key by `PerProjectStore`, so they need no handling
        // here — they were never plaintext on the relay.
        for (pid, bytes) in pull.sharedBytes {
            guard let store = sharedStores[pid] else { continue }
            _ = store.merge(encryptedBytes: bytes)
            merged = true
        }
        guard pull.attempted else { return merged }
        // A completed round-trip — including a 404 "no doc yet" and a 304
        // "unchanged" — tells us the relay's format. `blocked` doesn't
        // disqualify it: we read the bytes, we just couldn't use them.
        if pull.errorMessage == nil { relayProbed = true }
        let failure = pull.errorMessage ?? blocked
        let didMerge = merged
        DispatchQueue.main.async {
            guard let failure else {
                SyncSettings.shared.markServerHealth(.ok)
                // markMerged was historically only called from the manual
                // Sync Now button — so the diagnostics "last merged" line
                // stuck at whenever the user last tapped Refresh, even
                // though the poll had been pulling cleanly the whole time.
                // Recording it here gives an honest "auto-sync is alive"
                // signal. Gated on an actual merge: a 304 means "nothing
                // new", and claiming a merge then would be a lie.
                if didMerge { SyncSettings.shared.markMerged() }
                return
            }
            SyncSettings.shared.markServerHealth(.failing(failure))
        }
        return merged
    }

    /// Kick off a pull batch; `completion` runs on `queue` once the bytes
    /// are in hand. Returns false — having done nothing — outside server
    /// mode or when a batch is already in flight, in which case the caller
    /// should just get on with its local work.
    ///
    /// **Must be called from `queue`.**
    private func startPull(_ completion: @escaping (ServerPull) -> Void) -> Bool {
        guard !pullInFlight, let req = makePullRequest() else { return false }
        pullInFlight = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let pull = await Self.fetch(req)
            guard let self else { return }
            self.queue.async {
                self.pullInFlight = false
                completion(pull)
            }
        }
        return true
    }

    /// Run a pull batch to completion on the CALLING thread, for the one
    /// caller that needs a synchronous answer (`syncNow`).
    ///
    /// Never call this from the main thread or from `queue` — either would
    /// reintroduce the stall this split exists to remove — so those
    /// callers get an empty pull and pick peer changes up on the next poll
    /// instead. All three real `syncNow` call sites already hop to a
    /// background thread via `Task.detached`.
    private func blockingPull() -> ServerPull {
        guard !Thread.isMainThread,
              DispatchQueue.getSpecific(key: Self.queueKey) != queueID,
              let req = onQueue({ makePullRequest() }) else { return ServerPull() }
        let box = PullResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [box] in
            box.value = await TaskStorePersistence.fetch(req)
            semaphore.signal()
        }
        // Unbounded wait: `fetch` carries its own deadline. The old code
        // put the timeout on the semaphore instead, which left an
        // abandoned task still writing into a box we had already read.
        semaphore.wait()
        return box.value ?? ServerPull()
    }

    /// Mutable box for shuttling a network response back to the caller of
    /// `blockingPull`. The semaphore's signal/wait pair supplies the
    /// happens-before relationship that makes writing from the task and
    /// reading after `wait` safe without an explicit lock.
    private final class PullResultBox: @unchecked Sendable {
        var value: ServerPull?
    }

    /// Push the given main-doc bytes to the relay. Unconditional PUT —
    /// the app is local-first, so we never surrender a write on 412.
    /// Fire-and-forget: we do not block the persistence queue on the
    /// network round-trip. Errors surface on `SyncSettings.serverHealth`.
    private func pushMainToServer(_ bytes: Data) {
        guard let client = serverClient, let id = serverMainDocId else { return }
        guard let payload = sealForRelay(bytes) else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await client.put(id, payload)
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
    func startServerPollTimer() {
        stopServerPollTimer()
        guard serverClient != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 10 s cadence — keeps ETag-cached GETs (304s) cheap and
            // makes "peer added a task" land within ~10 s on the
            // viewer. Server traffic is negligible because the relay
            // returns 304 unless something actually changed.
            let t = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
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
    /// timer every 10 seconds when in server mode.
    ///
    /// Fire-and-forget: dispatches the (potentially blocking) work to
    /// the persistence queue via `queue.async`. **Must not** become
    /// `queue.sync` — the local half still does disk I/O that can stall
    /// on a file provider, and a sync dispatch from the main thread would
    /// freeze the UI for that long. Callers that need to observe the
    /// outcome should listen on `onExternalChange`.
    ///
    /// The relay round-trip happens *before* the queue work, off-queue —
    /// see `ServerPull`.
    func refreshFromDisk() {
        queue.async { [weak self] in
            guard let self else { return }
            let started = self.startPull { [weak self] pull in
                self?.applyRefresh(pull: pull)
            }
            // Local-only mode, or a slow batch already outliving its tick:
            // do the disk half now instead of stacking network work.
            if !started {
                self.applyRefresh(pull: ServerPull())
            }
        }
    }

    /// Queue-confined body of `refreshFromDisk`, run once the (possibly
    /// empty) server pull is in hand.
    private func applyRefresh(pull: ServerPull) {
        // Merge the relay's bytes first so disk + server state reconcile
        // in one pass.
        applyPull(pull)

        // If a local mutation is queued for the debounced save, promote
        // this refresh into a full flush. The bare merge/notify path below
        // would otherwise reload the UI from a doc that doesn't yet
        // contain the pending mutation — so a freshly-completed task
        // visibly comes back until flushNow runs. The pull above is
        // already merged in, so nothing is lost by routing through it.
        if pendingSnapshot != nil {
            flushNow()
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let bytes = readBytes(from: fileURL) {
            _ = mergeOrRebuild(bytes)
        }
        ingestConflictCopies()

        // After the main doc reconciles, adopt any share keys peers
        // published — same as in flushNow's step 2b. Hops to the
        // MainActor because adopt touches `MasterKey`.
        adoptShareKeysFromDoc()

        // Now that the main doc is current, open any newly shared
        // projects and reconcile each store against its local file.
        if let snap = try? automerge.snapshot() {
            refreshSharedStores(mainProjects: snap.projects)
        }
        for (_, store) in sharedStores {
            _ = store.refreshFromDisk()
            _ = store.ingestConflictCopies()
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
        // Server-mode pull before we take the queue — if the user just
        // enabled server mode we may not have any local file yet, but
        // remote state should still come through. Doing it out here keeps
        // the round-trip off the serial queue, which main-thread `load()`
        // calls are waiting on.
        let pull = blockingPull()
        return onQueue {
            if pendingSnapshot != nil {
                flushNow()
            }
            applyPull(pull)
            for (_, store) in sharedStores {
                _ = store.refreshFromDisk()
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

    /// Internal (not private) so the test bundle can drive the
    /// pendingSnapshot-vs-external-write race deterministically
    /// without depending on `DispatchSourceFileSystemObject` firing
    /// in test time. The body is wrapped in `onQueue` so callers on
    /// any thread are safe; the DispatchSource path is already on
    /// `queue` and `onQueue` short-circuits to inline execution in
    /// that case.
    func handleExternalEvent() {
        onQueue {
            // Same race-guard as `refreshFromDisk`: if a local
            // mutation is queued for the debounced save, promote
            // this external-change ingest into a full flush.
            // Otherwise the bare merge+notify below would reload
            // the UI from a doc that doesn't yet contain the
            // pending mutation — visible as a "task came back"
            // flicker whenever the MCP server (or any other
            // writer) touches the file during the 0.25 s save
            // window. `flushNow` absorbs disk state itself (step 1)
            // so nothing is lost by routing through it.
            if pendingSnapshot != nil {
                flushNow()
                startWatching()
                return
            }
            if let bytes = readBytes(from: fileURL) {
                _ = mergeOrRebuild(bytes)
                ingestConflictCopies()
                DispatchQueue.main.async { [weak self] in
                    SyncSettings.shared.markMerged()
                    self?.onExternalChange?()
                }
            }
            // Re-arm the watcher on the same queue we're on.
            startWatching()
        }
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
            // If we just switched into a server-backed mode, reconcile with
            // the relay so the remote catches up to the state we're
            // carrying forward.
            //
            // This goes through a full refresh rather than a bare push. We
            // have never read this relay, so we don't yet know whether it's
            // holding ciphertext — and a blind plaintext PUT is exactly the
            // downgrade `sealForRelay` refuses. `refreshFromDisk` pulls
            // first, which both answers that question and merges whatever a
            // peer already put there, then pushes the merged result.
            if !replaceLocalDoc, bytesForServer != nil, serverClient != nil {
                refreshFromDisk()
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

    // MARK: - Snapshot

    // `Snapshot` is now a top-level type (see `Snapshot.swift`) so the
    // MCP CLI target can use it without pulling in Persistence's iOS-
    // specific machinery. The typealias keeps existing call sites
    // (`TaskStorePersistence.Snapshot.…`) working unchanged.
    typealias Snapshot = TodarchySnapshot

    deinit {
        stopWatching()
        serverPollTimer?.invalidate()
    }
}
