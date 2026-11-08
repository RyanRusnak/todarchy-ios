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
    var serverClient: ServerSyncClient? {
        didSet {
            guard serverClient !== oldValue else { return }
            invalidatePushGate()
        }
    }

    /// Server-side id for the main doc. Paired with `serverClient`.
    var serverMainDocId: String? {
        didSet {
            guard serverMainDocId != oldValue else { return }
            invalidatePushGate()
        }
    }

    /// Re-arm the push gate so the next tick uploads regardless of what
    /// the previous transport already holds. Called whenever the relay
    /// identity or the sealing key changes — the bytes we skipped pushing
    /// last time are no longer the bytes *this* relay is missing.
    /// Both properties are written from the MainActor and read on the
    /// persistence queue, so hop.
    private func invalidatePushGate() {
        queue.async { [weak self] in
            self?.resetPushGate()
        }
    }

    /// Queue-confined body of `invalidatePushGate`.
    ///
    /// Bumping `pushEpoch` is what makes this stick. A PUT that was already
    /// in flight against the old relay or key would otherwise land after
    /// the reset and record its digest, and the gate would then believe
    /// the *new* relay already holds those bytes.
    private func resetPushGate() {
        pushEpoch &+= 1
        lastPushedDigest = nil
        lastPushedSharedDigests.removeAll()
    }

    /// 10-second foreground poll timer. Fires `refreshFromDisk` so the
    /// existing pipeline picks up server changes alongside file
    /// changes. Started by `setFileURL` when the server client is
    /// installed; cancelled otherwise.
    private var serverPollTimer: Timer?

    /// Key material for sealing the main doc on its way to the relay,
    /// paired with the Argon2 salt it was derived from — the salt rides
    /// in the envelope's clear header so another device holding only the
    /// passphrase can re-derive.
    ///
    /// `Equatable` so installing the same key again doesn't look like a
    /// rotation: `SyncSettings.refreshRelayKey` re-publishes on every
    /// master-key change, and treating a no-op re-install as a new key
    /// would re-arm the push gate and re-upload the whole doc.
    /// `SymmetricKey` has no public equality, so compare its encoding.
    struct RelayKey: Equatable {
        let key: SymmetricKey
        let salt: Data

        static func == (lhs: RelayKey, rhs: RelayKey) -> Bool {
            lhs.salt == rhs.salt && CryptoBox.encode(lhs.key) == CryptoBox.encode(rhs.key)
        }
    }

    private let relayKeyLock = NSLock()
    private var _relayKey: RelayKey?

    /// Installed by `SyncSettings` whenever the master key unlocks, locks,
    /// or its salt changes. Unlike everything else here it is *not*
    /// queue-confined — it's written from the MainActor and read from the
    /// persistence queue — so it carries its own lock.
    var relayKey: RelayKey? {
        get { relayKeyLock.lock(); defer { relayKeyLock.unlock() }; return _relayKey }
        set {
            relayKeyLock.lock()
            let changed = _relayKey != newValue
            _relayKey = newValue
            relayKeyLock.unlock()
            // A different key seals different ciphertext, so whatever we
            // last uploaded is no longer what this relay should hold.
            if changed { invalidatePushGate() }
        }
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

    /// The exact bytes currently sitting at `fileURL`, kept only when the
    /// live doc has already absorbed them. Queue-confined.
    ///
    /// This is what lets an idle sync tick cost nothing. A tick that found
    /// the file unchanged used to parse it, fork it, CRDT-merge it into
    /// itself, snapshot every task, re-serialize, do a coordinated
    /// `replaceItemAt` write, ChaCha20-seal the result and PUT the whole doc
    /// — then have its own write re-trigger the file watcher and do the
    /// merge half again. Comparing the bytes first collapses all of that to
    /// one memcmp, and because our own write-back records the digest here,
    /// the watcher it fires sees a match and goes quiet too. No suppression
    /// flag, no race: a write from MCP, Dropbox or a peer simply has
    /// different bytes and merges as before.
    ///
    /// `nil` until the first read or write of the current file, so the
    /// first tick always does the full pass.
    private var lastLocalBytes: Data?

    /// SHA-256 of the *plaintext* main-doc bytes behind the last
    /// **successful** relay PUT. Queue-confined.
    ///
    /// Deliberately separate from `lastLocalBytes`: "the disk hasn't moved"
    /// and "the relay is up to date" are independent conditions.
    /// `sealForRelay` refuses while the relay format is unprobed or the
    /// passphrase is locked, and `pushMainToServer` is fire-and-forget and
    /// can fail — so this is written only in the PUT's success path.
    /// Recording it at call time instead would swallow a local edit made
    /// while a request was in flight, and it would never reach the relay.
    ///
    /// Hashed rather than kept as bytes because sealing uses a fresh nonce
    /// every time, so the ciphertext is never reusable — only the plaintext
    /// identity is.
    private var lastPushedDigest: Data?

    /// Same gate as `lastPushedDigest`, per shared project, over the
    /// envelope bytes on that project's local cache file. Queue-confined.
    private var lastPushedSharedDigests: [String: Data] = [:]

    /// Incremented by `resetPushGate`. A PUT records its digest on success
    /// only if the epoch it started under is still current. Queue-confined.
    private var pushEpoch = 0

    /// One main-doc PUT at a time, latest bytes win. Queue-confined.
    ///
    /// The push gate stops a device re-uploading a doc the relay already
    /// has, which also means nothing re-pushes a doc the relay has *lost*.
    /// Two overlapping PUTs could land in the opposite order to how they
    /// were sent, leaving the older doc on the relay while the newer
    /// digest was recorded as pushed — and from then on every tick skipped
    /// the push. Serializing removes the reordering. A push requested while
    /// one is in flight is parked in `pendingMainPush`, replacing whatever
    /// was already parked, and goes out when the current one finishes.
    private var mainPushInFlight = false
    private var pendingMainPush: (bytes: Data, force: Bool)?

    /// Same discipline per shared project. The pending value is just the
    /// file to read: the push re-reads it at send time, so it always sends
    /// the newest envelope. Queue-confined.
    private var sharedPushesInFlight: Set<String> = []
    private var pendingSharedPushes: [String: URL] = [:]

    /// Shared projects whose last PUT failed. Re-attempted every tick so a
    /// blip doesn't strand the relay copy until this device edits that
    /// project again. Queue-confined.
    private var sharedPushesOwed: Set<String> = []

    /// Heads of the doc the canonical file is known to hold in full.
    /// Queue-confined.
    ///
    /// The refresh tick writes back whenever the live doc has moved past
    /// this. That covers a peer merge, and also a local write that failed:
    /// the edit is still in memory, so it has to keep being retried — the
    /// doc not moving this tick doesn't mean the disk caught up.
    ///
    /// Set after every successful write, and on reading the file to the
    /// heads of what it actually held, so a file that's behind the live
    /// doc gets brought up to date.
    private var diskHeads: Set<ChangeHash>?

    /// True while a share-key adoption still owes a retry. Queue-confined.
    /// `adoptShareKeysFromDoc` now only runs on ticks where the doc actually
    /// moved, so without this a device that adopts while its passphrase is
    /// locked would never pick the keys up — the doc may not change again
    /// for days, but unlocking it should still work.
    private var adoptPending = true

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

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
        queue.sync {
            // The doc was just built from these exact bytes, so they count
            // as already absorbed. Without seeding this, the first refresh
            // tick can't tell that nothing has moved.
            if let data {
                self.lastLocalBytes = data
                self.diskHeads = self.automerge.heads()
            }
            startWatching()
        }
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

        // An invitation can replace a key after a store has already opened.
        // The live store must use the new key as well as the keychain.
        for pid in sharedIds {
            if let existing = sharedStores[pid], let key = manager.keyStore.load(for: pid),
               existing.key.withUnsafeBytes({ Data($0) }) != key.withUnsafeBytes({ Data($0) }) {
                sharedStores.removeValue(forKey: pid)
                serverClient?.setCachedETag(nil, for: pid)
            }
            guard sharedStores[pid] == nil else { continue }
            if let store = manager.openStore(for: pid) {
                if let project = mainProjects.first(where: { $0.id == pid }) {
                    store.setPlaceholderProject(project)
                }
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
    /// because adopt touches `MasterKey` state. Fire-and-forget — a
    /// failure re-arms `adoptPending` so the next tick retries even
    /// when the doc itself hasn't moved.
    private func adoptShareKeysFromDoc() {
        let store = automerge
        let queue = self.queue
        adoptPending = false
        Task { @MainActor [weak self] in
            var needsRetry = false
            var imported = 0
            do {
                imported = try ShareKeysSync.shared.adoptFromDoc(store)
            } catch {
                needsRetry = true
                #if DEBUG
                print("todarchy: adoptShareKeysFromDoc failed: \(error)")
                #endif
            }
            // `adoptFromDoc` reports "nothing to do" both when the doc
            // genuinely has no cipher and when we're locked out of the
            // one it has. Only the second case is worth a retry.
            if !needsRetry,
               (try? store.readShareKeysSalt()) != nil,
               MasterKey.shared.currentKey == nil {
                needsRetry = true
            }
            let didImport = imported > 0
            queue.async { [weak self] in
                guard let self else { return }
                self.adoptPending = needsRetry
                if didImport {
                    // Adoption finishes after the original refresh. Open the
                    // stores now so the follow-up pull includes their ids.
                    if let projects = try? self.automerge.projects() {
                        self.refreshSharedStores(mainProjects: projects)
                    }
                    self.refreshFromDisk()
                    DispatchQueue.main.async { [weak self] in
                        self?.onExternalChange?()
                    }
                }
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

        // 1. Absorb anything the sync daemon dropped onto disk. Skipped
        //    when the file still holds bytes we've already merged — the
        //    common case while typing, and the difference between paying a
        //    full parse + fork + CRDT merge per save and paying none.
        if let onDisk = readMainDocBytes(), !alreadyAbsorbed(onDisk) {
            absorbDiskBytes(onDisk)
        }

        // 1b. No relay pull here, on purpose. This is the debounced
        //     save path — it runs while the user is typing — and awaiting
        //     a round-trip with the serial queue held is precisely what
        //     froze the UI on bad service. The relay's copy is merged by
        //     `applyRefresh` on the 10 s poll and by `syncNow`. Nothing is
        //     lost by not merging first: PUT is unconditional ("local
        //     always wins"), so a push that races a peer is reconciled on
        //     the next tick. Peers no longer re-push unconditionally every
        //     poll (see `pushMainToServer`'s gate); instead `applyPull`
        //     notices when the relay copy is missing changes we hold and
        //     re-arms the push, which converges the same way.

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
            // Promotion is a storage move, not a collaborative deletion.
            // Remove old main-doc copies only after their shared store exists.
            let movedTasks = try automerge.snapshot().tasks.filter { sharedIds.contains($0.list) }
            for task in movedTasks { try automerge.deleteTask(task.id) }
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
                               deletedTaskIds: deletes,
                               seedProject: false)
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
        let forceSharedIds: Set<String>
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
        // A key or invitation may have arrived since the last refresh.
        if let projects = try? automerge.projects() {
            refreshSharedStores(mainProjects: projects)
        }
        return PullRequest(client: client,
                           mainDocId: serverMainDocId,
                           sharedIds: Array(sharedStores.keys),
                           forceSharedIds: Set(sharedStores.compactMap { $0.value.needsInitialDownload ? $0.key : nil }))
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
                        do { return (pid, try await req.client.get(pid, useCache: !req.forceSharedIds.contains(pid))?.0, nil) }
                        catch { return (pid, nil, error.localizedDescription) }
                    }
                }
                for await (pid, bytes, failure) in group {
                    guard let pid else {
                        // Main doc: a nil `bytes` with no failure is a 304.
                        pull.mainBytes = bytes
                        if let failure { pull.errorMessage = failure }
                        continue
                    }
                    if let bytes { pull.sharedBytes[pid] = bytes }
                    if let failure {
                        pull.errorMessage = "Shared list download failed: \(failure)"
                    }
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
            //
            // That write-back is gated on the doc actually moving, and the
            // merge of our own history often doesn't move it. Drop the push
            // digest so the sealed upgrade goes up regardless.
            if relayKey != nil {
                lastPushedDigest = nil
            }
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

    /// What `applyPull` merged.
    private struct PullOutcome {
        /// True if any bytes were actually merged.
        var merged = false
        /// Heads of each shared-project relay doc merged this batch, keyed
        /// by project id. Lets the caller tell whether that relay copy is
        /// behind the local store once the rest of the tick has run.
        var sharedRelayHeads: [String: Set<ChangeHash>] = [:]
    }

    /// Merge a completed batch into the live docs and refresh the sync
    /// health indicators. **Must run on `queue`.**
    @discardableResult
    private func applyPull(_ pull: ServerPull) -> PullOutcome {
        var outcome = PullOutcome()
        var merged = false
        var blocked: String?
        if let bytes = pull.mainBytes {
            switch decodeRelayPayload(bytes) {
            case .plain(let plain):
                let remote = AutomergeStore(data: plain)
                do {
                    try automerge.merge(remote)
                } catch {
                    rebuildDoc(from: plain)
                }
                // The relay changed under us (this was a 200, not a 304).
                // If we hold changes it lacks, our heads now differ from its
                // — typically a peer's PUT raced ours and overwrote it. The
                // relay only learns them if we push, and the digest gate
                // would skip that push whenever our own bytes haven't moved,
                // so re-arm it.
                if remote.heads() != automerge.heads() {
                    lastPushedDigest = nil
                }
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
            guard let store = sharedStores[pid] else {
                // The roster can change while a request is in flight. A
                // discarded response must remain downloadable next time.
                serverClient?.setCachedETag(nil, for: pid)
                continue
            }
            guard let relayHeads = store.mergeReturningRemoteHeads(encryptedBytes: bytes) else {
                serverClient?.setCachedETag(nil, for: pid)
                blocked = "A shared list could not be decrypted. Reopen its invitation to refresh access."
                continue
            }
            outcome.sharedRelayHeads[pid] = relayHeads
            merged = true
        }
        outcome.merged = merged
        guard pull.attempted else { return outcome }
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
        return outcome
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
    ///
    /// Skipped when `bytes` are identical to what the last successful PUT
    /// already put there, unless `force` (only `syncNow`, where the user
    /// explicitly asked for a round trip). Sealing uses a fresh nonce per
    /// call, so re-uploading unchanged content produces different
    /// ciphertext and a new ETag — which is exactly what invalidated our
    /// own `If-None-Match` and turned each idle tick into a
    /// download-decrypt-merge-re-encrypt-upload loop that could never
    /// converge. Skipping the redundant PUT is what lets the relay's 304
    /// fast path fire again.
    ///
    /// At most one main-doc PUT is in flight; see `mainPushInFlight`.
    /// **Must run on `queue`.**
    private func pushMainToServer(_ bytes: Data, force: Bool = false) {
        guard let client = serverClient, let id = serverMainDocId else { return }
        if mainPushInFlight {
            // Latest bytes win, but a forced request stays forced even if a
            // later ordinary one replaces its bytes.
            let wasForced = pendingMainPush?.force ?? false
            pendingMainPush = (bytes, force || wasForced)
            return
        }
        let plaintextDigest = Self.digest(bytes)
        guard force || plaintextDigest != lastPushedDigest else { return }
        guard let payload = sealForRelay(bytes) else { return }
        mainPushInFlight = true
        let epoch = pushEpoch
        Task.detached(priority: .utility) { [queue, weak self] in
            var failure: String?
            do {
                _ = try await client.put(id, payload)
            } catch {
                failure = error.localizedDescription
            }
            queue.async {
                guard let self else { return }
                // Success path only: a PUT that fails, or a local edit that
                // lands while it's in flight, must still go out later. And
                // only for the relay + key this PUT was sealed for.
                if failure == nil, epoch == self.pushEpoch {
                    self.lastPushedDigest = plaintextDigest
                }
                self.mainPushInFlight = false
                if let next = self.pendingMainPush {
                    self.pendingMainPush = nil
                    // Re-runs the gate, so a parked copy of the bytes that
                    // just went up is dropped here rather than re-sent.
                    self.pushMainToServer(next.bytes, force: next.force)
                }
            }
            await MainActor.run {
                if let failure {
                    SyncSettings.shared.markServerHealth(.failing(failure))
                } else {
                    SyncSettings.shared.markServerHealth(.ok)
                }
            }
        }
    }

    /// Push a shared-project envelope (read from its local cache file)
    /// to the relay. Same unconditional semantics as `pushMainToServer`,
    /// and the same skip-when-identical gate — a shared file is re-sealed
    /// with a fresh nonce whenever it's rewritten, so an ungated push
    /// churns its ETag the same way.
    ///
    /// One PUT per project at a time, for the same reordering reason as
    /// the main doc. A request made while one is in flight re-reads the
    /// file when it runs, so it always sends the newest envelope. A failed
    /// PUT lands in `sharedPushesOwed` and is retried on the next tick.
    /// **Must run on `queue`.**
    private func pushSharedToServer(projectId: String, fileURL: URL) {
        guard let client = serverClient else { return }
        if sharedPushesInFlight.contains(projectId) {
            pendingSharedPushes[projectId] = fileURL
            return
        }
        guard let bytes = try? Data(contentsOf: fileURL) else { return }
        let envelopeDigest = Self.digest(bytes)
        guard envelopeDigest != lastPushedSharedDigests[projectId] else {
            sharedPushesOwed.remove(projectId)
            return
        }
        sharedPushesInFlight.insert(projectId)
        let epoch = pushEpoch
        Task.detached(priority: .utility) { [queue, weak self] in
            var ok = false
            do {
                _ = try await client.put(projectId, bytes)
                ok = true
            } catch {
                #if DEBUG
                print("todarchy: server PUT \(projectId) failed: \(error.localizedDescription)")
                #endif
            }
            queue.async {
                guard let self else { return }
                self.sharedPushesInFlight.remove(projectId)
                if ok, epoch == self.pushEpoch {
                    self.lastPushedSharedDigests[projectId] = envelopeDigest
                    self.sharedPushesOwed.remove(projectId)
                } else {
                    // Failed, or went to a relay we've since moved off.
                    self.sharedPushesOwed.insert(projectId)
                }
                if let next = self.pendingSharedPushes.removeValue(forKey: projectId) {
                    self.pushSharedToServer(projectId: projectId, fileURL: next)
                }
            }
        }
    }

    /// Start the foreground poll that pulls from the server at a steady
    /// cadence while the app is active. Idempotent; safe to call whenever
    /// the server client is installed.
    ///
    /// Both start and stop are main-confined. `Timer.invalidate()` only
    /// detaches a timer when it runs on the thread that scheduled it, so
    /// invalidating from the persistence queue left the old timer live
    /// while a new one was installed beside it — every mode switch leaked
    /// another 10 s poll, and each leaked timer kept ticking for the rest
    /// of the process lifetime.
    func startServerPollTimer() {
        guard serverClient != nil else {
            stopServerPollTimer()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serverPollTimer?.invalidate()
            // 10 s cadence — keeps ETag-cached GETs (304s) cheap and
            // makes "peer added a task" land within ~10 s on the
            // viewer. Server traffic is negligible because the relay
            // returns 304 unless something actually changed.
            let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                self?.refreshFromDisk()
            }
            // `.common` covers `.default` plus event tracking, so the poll
            // keeps firing during a scroll or an open menu. Registering it
            // here only — rather than `scheduledTimer` (which adds to
            // `.default`) plus an extra `.common` add — avoids putting the
            // same timer on the run loop twice.
            RunLoop.main.add(t, forMode: .common)
            self.serverPollTimer = t
        }
    }

    private func stopServerPollTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.serverPollTimer?.invalidate()
            self?.serverPollTimer = nil
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
    ///
    /// Returns the number of copies absorbed. Callers use it to decide
    /// whether a write-back is owed: absorbing a copy deletes the sibling
    /// file, so until the canonical one is rewritten its contents exist
    /// only in the live doc.
    @discardableResult
    private func ingestConflictCopies() -> Int {
        let dir = fileURL.deletingLastPathComponent()
        let canonical = fileURL.lastPathComponent
        let stem = (canonical as NSString).deletingPathExtension
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var absorbed = 0
        for entry in entries where entry != canonical
                                && entry.hasSuffix(".automerge")
                                && entry.hasPrefix(stem) {
            let url = dir.appendingPathComponent(entry)
            if let bytes = readBytes(from: url) {
                let other = AutomergeStore(data: bytes)
                try? automerge.merge(other)
                try? FileManager.default.removeItem(at: url)
                absorbed += 1
            }
        }
        return absorbed
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
        // Captured before the relay merge so "heads moved" covers both
        // the pull and the disk merge below. `heads()` neither serializes
        // nor parses, so bracketing the tick with it is free.
        let headsBefore = automerge.heads()
        // Same bracket per shared store. The relay merge inside `applyPull`
        // only changes a store's in-memory doc — its file doesn't move —
        // so per-call "did the file change" results can't see it. Comparing
        // heads across the whole tick catches every path a peer edit can
        // arrive by.
        let sharedHeadsBefore = sharedStores.mapValues { $0.heads() }

        // Merge the relay's bytes first so disk + server state reconcile
        // in one pass.
        let pulled = applyPull(pull)

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

        // Conflict copies are folded in before deciding whether to write:
        // absorbing one deletes the sibling file, so its contents exist
        // only in the live doc until the canonical file is rewritten. The
        // `diskHeads` comparison below sees that and writes it out.
        ingestConflictCopies()

        let diskBytes = readMainDocBytes()
        if !alreadyAbsorbed(diskBytes), let diskBytes {
            absorbDiskBytes(diskBytes)
        }

        let docChanged = automerge.heads() != headsBefore

        // After the main doc reconciles, adopt any share keys peers
        // published — same as in flushNow's step 2b. Hops to the
        // MainActor because adopt touches `MasterKey`.
        //
        // Skipped when the doc didn't move and no earlier attempt is
        // outstanding: the share-keys cipher can only have changed if
        // some op landed.
        if docChanged || adoptPending {
            adoptShareKeysFromDoc()
        }

        // Now that the main doc is current, open any newly shared
        // projects and reconcile each store against its local file.
        // `projects()` skips the task list, contexts and sorting — the
        // roster is all refreshSharedStores reads.
        if let projects = try? automerge.projects() {
            refreshSharedStores(mainProjects: projects)
        }
        for (_, store) in sharedStores {
            store.refreshFromDisk()
            store.ingestConflictCopies()
        }

        // A store opening or closing (a key arriving, an unshare) changes
        // what `load()` returns even if no doc moved.
        var sharedChanged = Set(sharedStores.keys) != Set(sharedHeadsBefore.keys)
        for (pid, store) in sharedStores {
            let heads = store.heads()
            if heads != sharedHeadsBefore[pid] { sharedChanged = true }

            // Relay merges and absorbed conflict copies otherwise live only
            // in memory until the user next edits this project.
            let persisted = (try? store.persistIfNeeded()) ?? false

            // Push when the relay is missing something we hold. If we pulled
            // its copy this tick we know exactly what it has; if not, only a
            // write we just made can have put something new on our side.
            var owesPush = sharedPushesOwed.contains(pid)
            if let relayHeads = pulled.sharedRelayHeads[pid] {
                if heads != relayHeads {
                    // The file may not have changed since our last PUT, so
                    // clear its digest or the gate would skip the push.
                    lastPushedSharedDigests[pid] = nil
                    owesPush = true
                }
            } else if persisted {
                owesPush = true
            }
            if owesPush {
                pushSharedToServer(projectId: pid, fileURL: store.fileURL)
            }
        }

        // Write back whenever the live doc holds anything the file doesn't:
        // a relay or disk merge, an absorbed conflict copy, or a local
        // write that failed last time. Comparing against `diskHeads`
        // rather than `headsBefore` is what keeps that last case retrying —
        // a failed write leaves the doc ahead of the disk without the doc
        // moving again.
        //
        // Deliberately not `retryOnPoison`. `save()` can't throw, so the only
        // failure here is the write itself, and that helper's recovery —
        // rebuild the doc from disk — would throw away exactly the
        // unwritten changes this branch exists to persist. On failure the
        // doc stays ahead of `diskHeads` and the next tick tries again.
        // The relay still gets the bytes: getting an edit off the device
        // shouldn't depend on the local folder being writable.
        var bytesToPush: Data?
        if automerge.heads() != diskHeads {
            let b = automerge.save()
            do {
                try writeBytes(b)
            } catch {
                #if DEBUG
                print("todarchy: refresh write-back failed, will retry next tick: \(error)")
                #endif
            }
            bytesToPush = b
        } else {
            // The file already holds the doc's current state. Reuse its
            // bytes rather than paying another serialize — pushMainToServer's
            // own digest gate decides whether they actually need to go up.
            bytesToPush = lastLocalBytes ?? automerge.save()
        }
        if let b = bytesToPush {
            pushMainToServer(b)
        }

        // Only notify when something a reader can see actually changed.
        // Every notification rebuilds the store's published arrays and
        // invalidates the whole SwiftUI tree, which is the bulk of what
        // an idle tick used to cost.
        //
        // `markChecked` rides along unconditionally — it isn't published,
        // so this hop is a dispatch and nothing more.
        let notify = docChanged || sharedChanged
        DispatchQueue.main.async { [weak self] in
            SyncSettings.shared.markChecked()
            if notify {
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
            // Use the same shared-store reconciliation as automatic sync:
            // downloaded envelopes must reach disk even without a local edit.
            applyRefresh(pull: pull)
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
                        pushMainToServer(b, force: true)
                        let count = load()?.tasks.count ?? 0
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
                pushMainToServer(b, force: true)
            }
            let count = load()?.tasks.count ?? 0
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
        // Recorded only once the write has landed. Recording on the way in
        // would let a failed write leave stale bytes on disk that the next
        // tick mistakes for already-absorbed.
        lastLocalBytes = data
        // Every caller passes `automerge.save()` from the same queue turn,
        // so the live heads are the heads of what just landed.
        diskHeads = automerge.heads()
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

    /// Read the canonical main-doc file, or `nil` when it's missing.
    private func readMainDocBytes() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return readBytes(from: fileURL)
    }

    /// True when `bytes` are byte-identical to what we last read from or
    /// wrote to the canonical file, so the live doc already contains them
    /// and a merge would add nothing.
    private func alreadyAbsorbed(_ bytes: Data?) -> Bool {
        guard let bytes, let known = lastLocalBytes else { return false }
        return bytes == known
    }

    /// Merge the canonical file's current bytes into the live doc and
    /// record them as the new disk baseline. **Must run on `queue`.**
    ///
    /// `diskHeads` becomes the heads of what the file actually holds, not
    /// the merged result. When the file is behind the live doc — an
    /// external writer put back an older copy, or our last write failed —
    /// the two differ and the next write-back check brings the file up to
    /// date.
    private func absorbDiskBytes(_ bytes: Data) {
        let onDisk = AutomergeStore(data: bytes)
        do {
            try automerge.merge(onDisk)
        } catch {
            // Poisoned live doc: same recovery as `mergeOrRebuild`.
            rebuildDoc(from: bytes)
        }
        lastLocalBytes = bytes
        diskHeads = onDisk.heads()
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
                // Our own `writeBytes` re-arms the watcher, so this fires
                // for writes we just made. Comparing against the bytes we
                // know are already in the doc turns that into a no-op —
                // no second merge, no second UI reload.
                let known = bytes == lastLocalBytes
                let headsBefore = automerge.heads()
                if !known {
                    absorbDiskBytes(bytes)
                }
                // A conflict copy is deleted once absorbed, so if we don't
                // persist the merge here the change lives only in memory.
                // Same for a file that turned out to be behind the live doc.
                // Outside server mode there's no poll tick to catch either.
                // Plain do/catch rather than `retryOnPoison`, for the reason
                // given in `applyRefresh`.
                let absorbed = ingestConflictCopies()
                if automerge.heads() != diskHeads {
                    do {
                        try writeBytes(automerge.save())
                    } catch {
                        #if DEBUG
                        print("todarchy: watcher write-back failed: \(error)")
                        #endif
                    }
                }
                if automerge.heads() != headsBefore || absorbed > 0 {
                    DispatchQueue.main.async { [weak self] in
                        SyncSettings.shared.markMerged()
                        self?.onExternalChange?()
                    }
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
            var targetBytes: Data?
            if FileManager.default.fileExists(atPath: newURL.path),
               let bytes = readBytes(from: newURL) {
                targetBytes = bytes
                if replaceLocalDoc {
                    rebuildDoc(from: bytes)
                } else {
                    _ = mergeOrRebuild(bytes)
                    ingestConflictCopies()
                }
            }
            self.fileURL = newURL
            // Every baseline we were tracking described the old URL and
            // the old relay. Clear them so the first tick against the new
            // destination is unconditional.
            lastLocalBytes = nil
            diskHeads = nil
            resetPushGate()
            var bytesForServer: Data?
            if replaceLocalDoc {
                // The doc was rebuilt verbatim from these bytes, so they
                // count as already absorbed.
                lastLocalBytes = targetBytes
                if targetBytes != nil { diskHeads = automerge.heads() }
            } else {
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
