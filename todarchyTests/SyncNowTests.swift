import XCTest
import Combine

@MainActor
final class SyncNowTests: XCTestCase {
    var tmpURL: URL!

    override func setUp() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-syncnow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        tmpURL = tmpDir.appendingPathComponent("tasks.automerge")
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())
    }

    // MARK: - syncNow on a clean file

    func testSyncNowReportsTaskCountOnSuccess() throws {
        let p = TaskStorePersistence(fileURL: tmpURL)
        p.saveNow(.init(
            tasks: [
                TaskItem(list: "inbox", title: "a", pos: Date()),
                TaskItem(list: "inbox", title: "b", pos: Date().addingTimeInterval(1))
            ],
            projects: []
        ))
        let result = p.syncNow()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.taskCount, 2)
        XCTAssertNil(result.message)
    }

    func testSyncNowMissingFileReturnsFailure() {
        // Point at a path whose file doesn't exist and whose parent also
        // doesn't exist — so the persistence watcher can't recreate it
        // under us. (Previously we relied on removeItem-after-init, but
        // the watcher fires on `.delete` and synchronously recreates the
        // file, so the missing-file window is too small to catch.)
        let bogusURL = tmpURL
            .deletingLastPathComponent()
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("never-written.automerge")
        let p = TaskStorePersistence(fileURL: bogusURL)
        // The init call created the parent dir and wrote empty bytes;
        // remove the whole tree (parent included) so the watcher can't
        // recreate the file.
        try? FileManager.default.removeItem(at: bogusURL.deletingLastPathComponent())
        let bad = p.syncNow()
        XCTAssertFalse(bad.success)
        XCTAssertNotNil(bad.message)
    }

    /// If the current in-memory doc is unusable (poisoned by a prior Rust
    /// panic), syncNow must still succeed by rebuilding from the on-disk
    /// bytes rather than letting the panic abort the user's session.
    /// We can't easily synthesize a poisoned doc here, so we assert the
    /// public behaviour: a regular sync returns `success = true` and the
    /// disk contents match afterwards.
    func testSyncNowRecoversFromSubsequentMergeFailures() throws {
        let p = TaskStorePersistence(fileURL: tmpURL)
        p.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "survivor", pos: Date())],
            projects: []
        ))
        // Run syncNow multiple times in a row — if recovery is broken,
        // PoisonError would surface on the second or third call.
        for _ in 0..<3 {
            let result = p.syncNow()
            XCTAssertTrue(result.success,
                           "syncNow should not bubble Rust panics to the user")
            XCTAssertNil(result.message)
        }
        let loaded = p.load()!
        XCTAssertTrue(loaded.tasks.contains { $0.title == "survivor" })
    }

    /// The load-bearing scenario: device A writes, device B reads via syncNow.
    func testSyncNowPullsExternalChangesFromDisk() throws {
        // A "writes" a task by saving to the URL directly through a separate
        // persistence instance — simulates another device's save landing
        // through the sync daemon.
        let external = TaskStorePersistence(fileURL: tmpURL)
        external.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "from other device", pos: Date())],
            projects: []
        ))

        // A second persistence instance reads the same file.
        let local = TaskStorePersistence(fileURL: tmpURL)

        let result = local.syncNow()
        XCTAssertTrue(result.success)

        let loaded = local.load()!
        XCTAssertTrue(loaded.tasks.contains { $0.title == "from other device" },
                       "syncNow must pull remote bytes into the local doc")
    }

    /// Two-direction sanity: A writes, B reads via syncNow, B writes, A reads.
    func testSyncNowBidirectional() throws {
        let a = TaskStorePersistence(fileURL: tmpURL)
        a.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "from A", pos: Date())],
            projects: []
        ))

        // B's local copy exists at a different path (the filesystem won't
        // actually move bytes for us in a unit test — so we stage B at its
        // own URL, syncNow-ing against a file we copied over manually.
        let bDir = tmpURL.deletingLastPathComponent()
            .appendingPathComponent("device-b", isDirectory: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        let bURL = bDir.appendingPathComponent("tasks.automerge")
        // Copy A's bytes to B's location.
        try FileManager.default.copyItem(at: tmpURL, to: bURL)

        let b = TaskStorePersistence(fileURL: bURL)
        b.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "from B", pos: Date())],
            projects: []
        ))
        // Now B's file has A's + B's tasks (after the pre-write merge path).
        // Copy B's bytes back to A's location (simulating Dropbox downloading
        // B's file to A's side).
        try FileManager.default.removeItem(at: tmpURL)
        try FileManager.default.copyItem(at: bURL, to: tmpURL)

        let result = a.syncNow()
        XCTAssertTrue(result.success)
        let titles = a.load()!.tasks.map(\.title)
        XCTAssertTrue(titles.contains("from A"))
        XCTAssertTrue(titles.contains("from B"))
    }

    // MARK: - SyncSettings wiring

    func testBeginSyncSetsIsSyncingFlag() {
        let s = SyncSettings.shared
        let before = s.isSyncing
        s.beginSync()
        XCTAssertTrue(s.isSyncing)
        s.endSync(result: .init(success: true, taskCount: 5, message: nil))
        XCTAssertFalse(s.isSyncing)
        _ = before
    }

    func testEndSyncSuccessUpdatesLastMerged() {
        let s = SyncSettings.shared
        s.endSync(result: .init(success: false, taskCount: nil, message: "staged error"))
        XCTAssertEqual(s.lastSyncError, "staged error")
        s.endSync(result: .init(success: true, taskCount: 3, message: nil))
        XCTAssertNil(s.lastSyncError)
        XCTAssertNotNil(s.lastMergedAt)
    }

    func testEndSyncFailureSetsError() {
        let s = SyncSettings.shared
        s.endSync(result: .init(success: false, taskCount: nil, message: "file not found"))
        XCTAssertEqual(s.lastSyncError, "file not found")
    }
}

// Shared state leaks between tests because SyncSettings.shared is a global.
// Tests that mutate it reset lastSyncError via endSync(.success) first so
// they're independent. No teardown hook needed.

#if os(macOS)
@MainActor
final class MacSyncShortcutTests: XCTestCase {
    func testSyncNowNotificationFires() {
        let exp = expectation(forNotification: .todarchySyncNow, object: nil)
        NotificationCenter.default.post(name: .todarchySyncNow, object: nil)
        wait(for: [exp], timeout: 1.0)
    }

    func testSyncResultEquatable() {
        let a = TaskStorePersistence.SyncResult(success: true, taskCount: 3, message: nil)
        let b = TaskStorePersistence.SyncResult(success: true, taskCount: 3, message: nil)
        XCTAssertEqual(a, b)
    }
}
#endif


/// The relay pull used to await its round-trip while holding the serial
/// persistence queue. `load()` reaches that queue with `queue.sync` from
/// the main thread, so a slow relay froze the UI for the length of the
/// wait x (1 + sharedStores.count) — "the app spontaneously hangs when I
/// have bad service". The fetch now runs off-queue and only the merge is
/// queued, so these two properties have to hold together: the UI stays
/// responsive *and* the bytes still land.
@MainActor
final class SlowServerPullTests: XCTestCase {
    var tmpURL: URL!
    let baseURL = URL(string: "https://mock.example.com")!

    override func setUp() async throws {
        MockURLProtocol.reset()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-slowpull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        tmpURL = tmpDir.appendingPathComponent("tasks.automerge")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        _ = try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())
    }

    private func attachServer(_ p: TaskStorePersistence, docId: String) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        p.serverClient = ServerSyncClient(baseURL: baseURL,
                                          session: URLSession(configuration: cfg))
        p.serverMainDocId = docId
    }

    func testLoadStaysResponsiveWhileAServerPullIsInFlight() async throws {
        let p = TaskStorePersistence(fileURL: tmpURL)
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "local", pos: Date())],
                        projects: []))

        let getIssued = expectation(description: "server GET issued")
        MockURLProtocol.stub(path: "/doc/slow_main", method: "GET") { _ in
            getIssued.fulfill()
            // Stand in for a bad-service round-trip. Runs on the URLProtocol's
            // own thread, so it can only stall the app if the persistence
            // queue is waiting on it.
            Thread.sleep(forTimeInterval: 2)
            return MockResponse(status: 404, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/slow_main", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p, docId: "slow_main")

        p.refreshFromDisk()
        await fulfillment(of: [getIssued], timeout: 5)

        // The GET is still in flight. This is the exact call the UI makes.
        let start = Date()
        let snap = p.load()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(snap)
        XCTAssertLessThan(elapsed, 1.0,
                          "load() waited \(elapsed)s on an in-flight server pull — the persistence queue is being held across the network round-trip again")
    }

    func testPulledBytesStillMergeOnceTheSlowGetReturns() async throws {
        let p = TaskStorePersistence(fileURL: tmpURL)
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "local", pos: Date())],
                        projects: []))

        // What the relay is holding: a peer's doc with a task we don't have.
        let peer = AutomergeStore(data: nil)
        try peer.upsertTasks([TaskItem(list: "inbox", title: "from-peer", pos: Date())])
        let peerBytes = peer.save()

        MockURLProtocol.stub(path: "/doc/lag_main", method: "GET") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return MockResponse(status: 200, headers: ["ETag": "\"v1\""], body: peerBytes)
        }
        MockURLProtocol.stub(path: "/doc/lag_main", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v2\""], body: Data())
        }
        attachServer(p, docId: "lag_main")

        let merged = expectation(description: "peer task merged into the local doc")
        merged.assertForOverFulfill = false
        p.onExternalChange = { [weak p] in
            guard let p else { return }
            if p.load()?.tasks.contains(where: { $0.title == "from-peer" }) == true {
                merged.fulfill()
            }
        }

        p.refreshFromDisk()
        await fulfillment(of: [merged], timeout: 10)

        let snap = p.load()
        XCTAssertTrue(snap?.tasks.contains { $0.title == "from-peer" } ?? false)
        XCTAssertTrue(snap?.tasks.contains { $0.title == "local" } ?? false,
                      "Merging the relay's copy must not drop local state.")
    }
}

// MARK: - Idle sync cost

private enum IdleFixture {
    static let relayKey = TaskStorePersistence.RelayKey(
        key: CryptoBox.generateKey(),
        salt: Data(repeating: 0x5A, count: 16)
    )
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class BodyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func add(_ data: Data) { lock.lock(); bodies.append(data); lock.unlock() }
    var value: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var value: Data? {
        get { lock.lock(); defer { lock.unlock() }; return data }
        set { lock.lock(); data = newValue; lock.unlock() }
    }
}

/// Counts `objectWillChange` emissions. `@Published` fires on `willSet`, so
/// the count is exact the moment the mutating call returns — no awaiting.
private final class EmissionCounter {
    private var count = 0
    private var token: AnyCancellable?

    @MainActor
    init<O: ObservableObject>(_ object: O) {
        token = object.objectWillChange.sink { [weak self] _ in self?.count += 1 }
    }
    var value: Int { count }
}

/// An idle todokase used to burn ~13% of a core doing nothing. Every 10 s
/// poll parsed the doc, forked it, CRDT-merged it into itself, snapshotted
/// every task, re-serialized, rewrote the file, ChaCha20-sealed the result,
/// PUT the whole doc, then had its own write re-trigger the file watcher and
/// do the merge half again — and every one of those steps published to
/// SwiftUI. These tests pin the gates that removed it.
@MainActor
final class IdleSyncCostTests: XCTestCase {
    var tmpDir: URL!
    var fileURL: URL!
    let baseURL = URL(string: "https://mock.example.com")!
    let docId = "main_idle"

    override func setUp() async throws {
        MockURLProtocol.reset()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-idle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        fileURL = tmpDir.appendingPathComponent("tasks.automerge")
        // The no-downgrade flag is process-wide; start clean.
        UserDefaults.standard.set(false, forKey: "todarchy.sync.relayEncrypted")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        UserDefaults.standard.set(false, forKey: "todarchy.sync.relayEncrypted")
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    private func attachServer(_ p: TaskStorePersistence) {
        p.serverClient = ServerSyncClient(baseURL: baseURL,
                                          session: MockURLProtocol.makeSession())
        p.serverMainDocId = docId
    }

    /// Drive one poll tick to completion, failing the test if it never
    /// finishes.
    ///
    /// A tick that found nothing fires no callback, so there's nothing to
    /// await on the persistence side. `lastCheckedAt` is written at the end
    /// of every `applyRefresh` — including the ones that bail — which makes
    /// it the only honest "this tick finished" signal.
    private func runTick(_ p: TaskStorePersistence,
                         timeout: TimeInterval = 5,
                         file: StaticString = #filePath,
                         line: UInt = #line) async {
        let before = SyncSettings.shared.lastCheckedAt
        p.refreshFromDisk()
        let deadline = Date().addingTimeInterval(timeout)
        while SyncSettings.shared.lastCheckedAt == before {
            if Date() > deadline {
                XCTFail("Poll tick never completed — `markChecked` didn't run within \(timeout)s",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func mtime() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    // MARK: - The idle tick itself

    func testIdleTicksDoNotRewritePushOrNotify() async throws {
        let gets = Counter()
        let puts = Counter()
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            gets.bump()
            return MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            puts.bump()
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        // Installed before the save, so the watcher event our own write
        // triggers is counted too. That self-trigger used to run a second
        // full merge and a second UI reload per tick.
        let notified = Counter()
        p.onExternalChange = { notified.bump() }

        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "idle", pos: Date())],
                        projects: []))
        // The save pushes on its own (sealing never downgrades, so it doesn't
        // need the relay's format first). Drain that, plus the tick below, so
        // everything after measures steady state.
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        let baseline = puts.value
        XCTAssertGreaterThanOrEqual(baseline, 1, "The relay should have our bytes by now.")
        let afterSave = notified.value
        XCTAssertEqual(afterSave, 1,
                       "The save's own flush notifies once. A second emission would mean the write re-triggered the file watcher into a full merge — the loop this gate exists to break.")

        let before = try mtime()
        XCTAssertNotNil(before)

        for _ in 0..<5 {
            await runTick(p)
        }
        // Leave room for a stray watcher-driven merge to land before
        // asserting that none did.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(gets.value, 6,
                       "The gate is on work, not on polling — every tick must still reach the relay.")
        XCTAssertEqual(puts.value, baseline,
                       "A 304 plus unchanged local bytes must not produce a PUT.")
        XCTAssertEqual(notified.value, afterSave,
                       "Nothing changed, so the UI must not be told to reload.")
        XCTAssertEqual(try mtime(), before, "An idle tick must not rewrite the doc.")
    }

    /// The push gate records the plaintext digest of the last successful
    /// PUT, so a genuine edit has to produce different bytes and go up. The
    /// failure mode this catches is recording the digest at call time rather
    /// than in the success path: an edit made while a request is in flight
    /// would then look already-pushed and never reach the relay.
    func testAnEditAfterARecordedPushStillGetsPushed() async throws {
        let bodies = BodyCollector()
        let puts = Counter()
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            puts.bump()
            bodies.add(request.httpBody ?? MockURLProtocol.streamedBody(from: request) ?? Data())
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "first", pos: Date())],
                        projects: []))
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterFirst = puts.value
        XCTAssertGreaterThanOrEqual(afterFirst, 1)

        p.saveNow(.init(tasks: [
            TaskItem(list: "inbox", title: "first", pos: Date()),
            TaskItem(list: "inbox", title: "second", pos: Date().addingTimeInterval(1)),
        ], projects: []))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(puts.value, afterFirst + 1,
                       "A real edit must reach the relay even though an identical digest was recorded moments ago.")
        let plain = try CryptoBox.open(try XCTUnwrap(bodies.value.last),
                                       with: IdleFixture.relayKey.key)
        let titles = try AutomergeStore(data: plain).snapshot().tasks.map(\.title)
        XCTAssertTrue(titles.contains("second"))
        XCTAssertTrue(titles.contains("first"))
    }

    /// Sealing uses a fresh nonce every time, so the relay's bytes are never
    /// byte-identical to ours and "unchanged" can't be detected by comparing
    /// ciphertexts. The push gate hashes the *plaintext* instead. This is the
    /// case that gate could quietly break: a pre-encryption relay copy whose
    /// contents we already hold.
    func testLegacyPlaintextOnTheRelayIsResealedEvenWhenTheDocHasNotMoved() async throws {
        let puts = Counter()
        let bodies = BodyCollector()
        let served = DataBox()
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            if let plain = served.value {
                return MockResponse(status: 200, headers: ["ETag": "\"v9\""], body: plain)
            }
            return MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            puts.bump()
            bodies.add(request.httpBody ?? MockURLProtocol.streamedBody(from: request) ?? Data())
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "mine", pos: Date())], projects: []))
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterFirst = puts.value
        XCTAssertGreaterThanOrEqual(afterFirst, 1)

        // Hand back our own doc, unsealed — exactly what an older build left
        // on the relay. Merging it cannot move the doc, so without an
        // explicit reset of the push gate the sealed upgrade never goes up.
        served.value = try Data(contentsOf: fileURL)
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(puts.value, afterFirst + 1,
                       "Legacy plaintext must be re-uploaded sealed even though the merge changed nothing.")
        XCTAssertTrue(CryptoBox.isEnvelope(try XCTUnwrap(bodies.value.last)),
                      "The upgrade PUT must be sealed, not plaintext.")
    }

    /// Absorbing a conflict copy deletes the sibling file, so the merged
    /// content exists only in memory until the canonical file is rewritten.
    /// The idle gate must not swallow that write.
    func testConflictCopyIsAbsorbedAndWrittenBackToDisk() async throws {
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)

        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "mine", pos: Date())], projects: []))
        await runTick(p)

        let peer = AutomergeStore(data: try Data(contentsOf: fileURL))
        try peer.upsertTasks([TaskItem(list: "inbox", title: "from-conflict-copy", pos: Date())])
        let conflictURL = tmpDir
            .appendingPathComponent("tasks (MacBook's conflicted copy 2026-04-20).automerge")
        try peer.save().write(to: conflictURL)

        let notified = expectation(description: "conflict copy absorbed")
        notified.assertForOverFulfill = false
        p.onExternalChange = { notified.fulfill() }

        await runTick(p)
        await fulfillment(of: [notified], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictURL.path),
                       "Absorbing a conflict copy must remove the sibling file.")
        let inMemory = try XCTUnwrap(p.load()).tasks.map(\.title)
        XCTAssertTrue(inMemory.contains("from-conflict-copy"))
        XCTAssertTrue(inMemory.contains("mine"))
        let onDisk = try AutomergeStore(data: try Data(contentsOf: fileURL)).snapshot().tasks.map(\.title)
        XCTAssertTrue(onDisk.contains("from-conflict-copy"),
                      "The absorbed copy has to reach disk, not just the live doc.")
    }

    // MARK: - Publication discipline

    /// `SyncSettings` is observed by the root view, so every `@Published`
    /// write rebuilds the settings surface. A poll tick that found nothing
    /// used to write `serverHealth`, `relayEncryption` and `relayEnvelopeSalt`
    /// anyway.
    func testUnchangedSyncStatePublishesNothing() async {
        let settings = SyncSettings.shared
        settings.markServerHealth(.ok)
        let emissions = EmissionCounter(settings)

        settings.markServerHealth(.ok)
        settings.markServerHealth(.ok)
        XCTAssertEqual(emissions.value, 0, "Re-reporting the same health must not invalidate observers.")

        settings.markChecked()
        settings.markChecked()
        XCTAssertEqual(emissions.value, 0, "`lastCheckedAt` moves every tick and must stay unpublished.")
        XCTAssertNotNil(settings.lastCheckedAt)

        settings.markServerHealth(.failing("boom"))
        XCTAssertEqual(emissions.value, 1)
        settings.markServerHealth(.failing("boom"))
        XCTAssertEqual(emissions.value, 1, "An identical failure message is not a new state.")
        settings.markServerHealth(.ok)
        XCTAssertEqual(emissions.value, 2)

        let salt = Data(repeating: 7, count: 16)
        settings.noteRelayEnvelopeSalt(salt)
        let afterFirstSalt = emissions.value
        XCTAssertGreaterThan(afterFirstSalt, 2)
        settings.noteRelayEnvelopeSalt(salt)
        XCTAssertEqual(emissions.value, afterFirstSalt,
                       "A locked device sees the same unreadable envelope every tick.")
    }

    /// `adoptSalt` runs on every main-doc merge, and re-assigning the
    /// published key pair each time is what made `SyncSettings` re-derive
    /// and re-publish the relay key on every tick.
    func testAdoptingTheSameSaltTwicePublishesOnce() async throws {
        let key = MasterKey(cache: InMemoryMasterKeyCache())
        let salt = Data(repeating: 1, count: 16)
        try key.setDerivedKey(Data(repeating: 2, count: 32), salt: salt)

        let emissions = EmissionCounter(key)
        key.adoptSalt(salt)
        key.adoptSalt(salt)
        XCTAssertEqual(emissions.value, 0, "The cached key already matches this salt.")
        XCTAssertNotNil(key.currentKey)

        // A real passphrase change still publishes — once per property in the
        // (`currentKey`, `currentSalt`) pair, which is what clearing costs.
        key.adoptSalt(Data(repeating: 3, count: 16))
        XCTAssertEqual(emissions.value, 2)
        XCTAssertNil(key.currentKey)
        key.adoptSalt(Data(repeating: 3, count: 16))
        XCTAssertEqual(emissions.value, 2, "Clearing an already-cleared key must not publish again.")
    }

    // MARK: - Gate side effects

    private func titles(inRelayBody body: Data) throws -> [String] {
        let plain = try CryptoBox.open(body, with: IdleFixture.relayKey.key)
        return try AutomergeStore(data: plain).snapshot().tasks.map(\.title)
    }

    /// A shared project's relay copy is merged into the store's in-memory
    /// doc, but its local file doesn't change, so "did the file move" can't
    /// see it. The UI has to be told anyway, and the merge has to reach the
    /// local cache file, or a collaborator's edit stays invisible until
    /// something unrelated triggers a reload.
    func testCollaboratorEditFromRelayReachesUIAndDisk() async throws {
        let manager = SharedProjectManager(folder: tmpDir, keyStore: InMemoryKeyStore())
        let project = ProjectItem(id: "p_collab", name: "collab", icon: "folder",
                                  accent: .blue, isShared: true)
        let mine = TaskItem(list: project.id, title: "mine", pos: Date())
        let (sharedURL, key) = try manager.createShared(project: project, tasks: [mine])

        let p = TaskStorePersistence(fileURL: fileURL)
        p.sharedProjectManager = manager
        let sharedPuts = Counter()
        let served = DataBox()
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"m1\""], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(project.id)", method: "GET") { _ in
            guard let body = served.value else {
                return MockResponse(status: 304, headers: [:], body: Data())
            }
            return MockResponse(status: 200, headers: ["ETag": "\"s2\""], body: body)
        }
        MockURLProtocol.stub(path: "/doc/\(project.id)", method: "PUT") { _ in
            sharedPuts.bump()
            return MockResponse(status: 204, headers: ["ETag": "\"s1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        p.saveNow(.init(tasks: [mine], projects: [project]))
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)

        // A collaborator, working from the same envelope, adds a task and
        // pushes. Only the relay carries it — nothing touches our file.
        let peerDir = tmpDir.appendingPathComponent("peer", isDirectory: true)
        try FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)
        let peerURL = peerDir.appendingPathComponent(sharedURL.lastPathComponent)
        try FileManager.default.copyItem(at: sharedURL, to: peerURL)
        let peer = PerProjectStore(fileURL: peerURL, projectId: project.id, key: key)
        try peer.save(.init(tasks: [mine, TaskItem(list: project.id, title: "from-collaborator",
                                                   pos: Date().addingTimeInterval(1))],
                            project: project))
        served.value = try Data(contentsOf: peerURL)

        let notified = Counter()
        p.onExternalChange = { notified.bump() }
        let putsBefore = sharedPuts.value

        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertGreaterThanOrEqual(notified.value, 1,
                                    "A collaborator's edit arriving via the relay must reload the UI.")
        XCTAssertTrue(try XCTUnwrap(p.load()).tasks.contains { $0.title == "from-collaborator" })
        let onDisk = try PerProjectStore(fileURL: sharedURL, projectId: project.id, key: key)
            .readSnapshot().tasks.map(\.title)
        XCTAssertTrue(onDisk.contains("from-collaborator"),
                      "The relay merge must reach the local cache file, not just memory.")
        XCTAssertEqual(sharedPuts.value, putsBefore,
                       "The relay already holds everything we have, so nothing should go back up.")

        // Same relay bytes again: nothing new, so no reload and no push.
        let notifiedAfter = notified.value
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(notified.value, notifiedAfter, "Re-merging known relay bytes must stay quiet.")
        XCTAssertEqual(sharedPuts.value, putsBefore)
    }

    /// The push gate means devices stop re-pushing on every poll, so it's
    /// the pull's job to notice when the relay has lost something. Here a
    /// stale copy (a peer's PUT that raced ours) replaces the relay doc.
    /// Merging it doesn't move our doc and our bytes haven't changed, so the
    /// digest gate alone would skip the push and the relay would stay stale.
    func testRelayThatFellBehindIsPushedTheMissingChanges() async throws {
        let puts = Counter()
        let bodies = BodyCollector()
        let served = DataBox()
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            guard let body = served.value else {
                return MockResponse(status: 304, headers: [:], body: Data())
            }
            return MockResponse(status: 200, headers: ["ETag": "\"v9\""], body: body)
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            puts.bump()
            bodies.add(request.httpBody ?? MockURLProtocol.streamedBody(from: request) ?? Data())
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        let first = TaskItem(list: "inbox", title: "first", pos: Date())
        p.saveNow(.init(tasks: [first], projects: []))
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stale = try Data(contentsOf: fileURL)

        p.saveNow(.init(tasks: [first, TaskItem(list: "inbox", title: "second",
                                                pos: Date().addingTimeInterval(1))],
                        projects: []))
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterSecond = puts.value

        served.value = try CryptoBox.seal(stale, with: IdleFixture.relayKey.key,
                                          salt: IdleFixture.relayKey.salt)
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(puts.value, afterSecond + 1,
                       "A relay copy missing our changes must be re-pushed.")
        let pushed = try titles(inRelayBody: try XCTUnwrap(bodies.value.last))
        XCTAssertTrue(pushed.contains("second"), "The re-push must carry the change the relay lost.")

        // And it converges: once the relay holds everything, a 200 carrying
        // our own content must not bounce back up.
        served.value = bodies.value.last
        await runTick(p)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(puts.value, afterSecond + 1,
                       "A relay that's caught up must not trigger another push.")
    }

    /// Overlapping PUTs can land in either order, and with the push gate
    /// nothing would repair the relay if the older one landed last. Only
    /// one PUT is in flight at a time; requests made meanwhile collapse to
    /// the latest bytes.
    func testPushesWhileOneIsInFlightCollapseToTheLatest() async throws {
        let puts = Counter()
        let bodies = BodyCollector()
        let p = TaskStorePersistence(fileURL: fileURL)
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in
            MockResponse(status: 304, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            puts.bump()
            bodies.add(request.httpBody ?? MockURLProtocol.streamedBody(from: request) ?? Data())
            Thread.sleep(forTimeInterval: 0.3)   // a slow relay
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        attachServer(p)
        p.relayKey = IdleFixture.relayKey

        var tasks: [TaskItem] = []
        for i in 0..<3 {
            tasks.append(TaskItem(list: "inbox", title: "edit-\(i)",
                                  pos: Date().addingTimeInterval(Double(i))))
            p.saveNow(.init(tasks: tasks, projects: []))
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(puts.value, 2,
                       "Three saves during one in-flight PUT should send the first, then only the latest.")
        let last = try titles(inRelayBody: try XCTUnwrap(bodies.value.last))
        XCTAssertTrue(last.contains("edit-2"), "The coalesced push must carry the newest state.")
    }

    /// A save whose disk write failed leaves the edit only in memory. The
    /// next tick finds the doc and the file unchanged since it started, so a
    /// "did anything move this tick" test skips the write-back and the edit
    /// is lost on quit. Comparing against what the file actually holds
    /// keeps retrying until the write lands.
    func testFailedLocalWriteIsRetriedOnTheNextTick() async throws {
        let p = TaskStorePersistence(fileURL: fileURL)
        let first = TaskItem(list: "inbox", title: "first", pos: Date())
        p.saveNow(.init(tasks: [first], projects: []))

        // The atomic write stages a sibling `.tmp`, so a read-only folder
        // makes it fail while the existing file stays readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmpDir.path)
        p.saveNow(.init(tasks: [first, TaskItem(list: "inbox", title: "unwritten",
                                                pos: Date().addingTimeInterval(1))],
                        projects: []))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir.path)

        let beforeRetry = try AutomergeStore(data: try Data(contentsOf: fileURL)).snapshot().tasks.map(\.title)
        XCTAssertFalse(beforeRetry.contains("unwritten"),
                       "Precondition: the write must actually have failed.")

        await runTick(p)

        let afterRetry = try AutomergeStore(data: try Data(contentsOf: fileURL)).snapshot().tasks.map(\.title)
        XCTAssertTrue(afterRetry.contains("unwritten"),
                      "The next tick must write out the edit the failed save left in memory.")
    }
}
