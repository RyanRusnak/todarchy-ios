import XCTest

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
