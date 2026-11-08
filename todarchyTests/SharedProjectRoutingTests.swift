import XCTest
import CryptoKit
@testable import todarchy

/// Phase 3c routing: tasks for shared projects live in encrypted
/// per-project files and only appear in TaskStorePersistence.load()
/// because the persistence unions them with the main doc.
@MainActor
final class SharedProjectRoutingTests: XCTestCase {
    var syncFolder: URL!
    var mainFile: URL!
    var keyStore: InMemoryKeyStore!
    var manager: SharedProjectManager!

    override func setUp() async throws {
        syncFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        mainFile = syncFolder.appendingPathComponent("tasks.automerge")
        keyStore = InMemoryKeyStore()
        manager = SharedProjectManager(folder: syncFolder, keyStore: keyStore)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: syncFolder)
    }

    private func makePersistence() -> TaskStorePersistence {
        let p = TaskStorePersistence(fileURL: mainFile)
        p.sharedProjectManager = manager
        return p
    }

    func testInviteDoesNotUploadPlaceholderBeforeFirstDownload() throws {
        let key = CryptoBox.generateKey()
        let pid = "p_invite"
        try keyStore.save(key, for: pid)
        let placeholder = ProjectItem(id: pid, name: "shared project", icon: "person.2.fill",
                                      accent: .orange, isShared: true)
        let p = makePersistence()
        p.saveNow(.init(tasks: [], projects: [placeholder]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: pid).path),
                       "Joining must not publish an empty doc over the owner's relay copy")

        // An offline edit while waiting must survive the initial download.
        let bread = TaskItem(list: pid, title: "bread", pos: Date())
        p.saveNow(.init(tasks: [bread], projects: [placeholder]))
        XCTAssertEqual(p.load()?.tasks.map(\.id), [bread.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: pid).path))

        let restarted = makePersistence()
        XCTAssertEqual(restarted.load()?.tasks.map(\.id), [bread.id],
                       "Edits waiting for the first download must survive restart")
        let ownerURL = syncFolder.appendingPathComponent("owner.automerge.enc")
        let owner = PerProjectStore(fileURL: ownerURL, projectId: pid, key: key)
        let groceries = ProjectItem(id: pid, name: "Groceries", icon: "cart", accent: .orange,
                                    isShared: true)
        let milk = TaskItem(list: pid, title: "milk", pos: Date())
        try owner.save(.init(tasks: [milk], project: groceries))
        try FileManager.default.copyItem(at: ownerURL, to: manager.fileURL(for: pid))
        // Flush a UI snapshot still carrying the pre-download placeholder.
        p.saveNow(.init(tasks: [bread], projects: [placeholder]))
        XCTAssertEqual(p.load()?.projects.first?.name, "Groceries")
        XCTAssertEqual(Set(p.load()!.tasks.map(\.id)), Set([milk.id, bread.id]))
        let reopened = try XCTUnwrap(manager.openStore(for: pid))
        XCTAssertEqual(try reopened.readSnapshot().project.name, "Groceries")
        XCTAssertEqual(Set(try reopened.readSnapshot().tasks.map(\.id)), Set([milk.id, bread.id]))
    }

    func testServerInviteDownloadsSharedListWithoutSharingPrivateLists() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let pid = "p_server_groceries"
        let key = CryptoBox.generateKey()
        let ownerURL = syncFolder.appendingPathComponent("owner.enc")
        let owner = PerProjectStore(fileURL: ownerURL, projectId: pid, key: key)
        let groceries = ProjectItem(id: pid, name: "Groceries", icon: "cart", accent: .orange,
                                    isShared: true)
        let milk = TaskItem(list: pid, title: "milk", pos: Date())
        try owner.save(.init(tasks: [milk], project: groceries))
        let envelope = try Data(contentsOf: ownerURL)
        MockURLProtocol.stub(path: "/doc/recipient_private", method: "GET") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/recipient_private", method: "PUT") { _ in
            MockResponse(status: 204, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(pid)", method: "GET") { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "owner-v1" {
                return MockResponse(status: 304, headers: [:], body: Data())
            }
            return MockResponse(status: 200, headers: ["ETag": "owner-v1"], body: envelope)
        }
        MockURLProtocol.stub(path: "/doc/\(pid)", method: "PUT") { _ in
            MockResponse(status: 204, headers: [:], body: Data())
        }

        let p = makePersistence()
        let privateList = ProjectItem(id: "p_private", name: "Private", icon: "folder", accent: .blue)
        let privateTask = TaskItem(list: privateList.id, title: "private task", pos: Date())
        p.saveNow(.init(tasks: [privateTask], projects: [privateList]))
        let ui = TaskStore(persistence: p)
        _ = try ui.acceptPayload(.init(projectId: pid, key: key), manager: manager)
        // Flush the invite before connecting so the reader is registered.
        XCTAssertTrue(p.syncNow().success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: pid).path))
        p.serverClient = ServerSyncClient(baseURL: URL(string: "https://mock.example.com")!, session: session)
        p.serverMainDocId = "recipient_private"
        // Reproduce the live Mac failure: the HTTP response was cached, but
        // its contents never reached the placeholder store. The next sync
        // must request the full document instead of accepting 304 forever.
        p.serverClient?.setCachedETag("owner-v1", for: pid)
        let result = await Task.detached { p.syncNow() }.value
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.taskCount, 2, "Sync status must include shared tasks")
        XCTAssertEqual(p.load()?.projects.first(where: { $0.id == pid })?.name, "Groceries")
        XCTAssertEqual(Set(p.load()!.tasks.map(\.id)), Set([privateTask.id, milk.id]))

        // A manual download must be durable before the next poll or edit.
        let received = try XCTUnwrap(manager.openStore(for: pid))
        XCTAssertEqual(try received.readSnapshot().tasks.map(\.id), [milk.id])
        XCTAssertEqual(try received.readSnapshot().project.name, "Groceries")
        let main = AutomergeStore(data: try Data(contentsOf: mainFile))
        XCTAssertEqual(try main.snapshot().tasks.map(\.id), [privateTask.id])
    }

    func testReplacingInvitationKeyReopensLiveStore() throws {
        let pid = "p_rekey"
        let project = ProjectItem(id: pid, name: "Shared", icon: "cart", accent: .orange, isShared: true)
        _ = try manager.createShared(project: project, tasks: [])
        let p = makePersistence()
        p.saveNow(.init(tasks: [], projects: [project]))
        XCTAssertEqual(p.load()?.tasks.count, 0)

        let currentKey = CryptoBox.generateKey()
        let ownerURL = syncFolder.appendingPathComponent("current-owner.enc")
        let owner = PerProjectStore(fileURL: ownerURL, projectId: pid, key: currentKey)
        let task = TaskItem(list: pid, title: "Newly accessible", pos: Date())
        try owner.save(.init(tasks: [task], project: project))
        try Data(contentsOf: ownerURL).write(to: manager.fileURL(for: pid), options: .atomic)
        try keyStore.save(currentKey, for: pid)
        XCTAssertEqual(p.load()?.tasks.map(\.id), [task.id],
                       "A running reader must adopt a replacement invitation key")
    }

    // MARK: - Union load

    func testLoadUnionsMainDocAndSharedStore() throws {
        // Set up the main doc with a personal task + a project that
        // will become shared.
        let work = ProjectItem(id: "p_work", name: "work", icon: "briefcase", accent: .blue)
        let grocery = ProjectItem(id: "p_groc", name: "groceries", icon: "cart", accent: .orange)

        let p1 = makePersistence()
        p1.saveNow(.init(
            tasks: [TaskItem(list: "p_work", title: "write spec", pos: Date())],
            projects: [work, grocery]
        ))

        // Promote groceries to shared via the manager directly (the
        // TaskStore-level promotion path is exercised elsewhere).
        _ = try manager.createShared(project: grocery,
                                      tasks: [TaskItem(list: "p_groc", title: "milk", pos: Date())])

        // Main doc now needs grocery.isShared = true so load() opens
        // the shared store on its next refresh.
        var shared = grocery
        shared.isShared = true
        p1.saveNow(.init(tasks: [TaskItem(list: "p_work", title: "write spec", pos: Date())],
                          projects: [work, shared]))

        // Fresh persistence instance — simulates app restart.
        let p2 = makePersistence()
        let snap = p2.load()!
        let titles = Set(snap.tasks.map(\.title))
        XCTAssertTrue(titles.contains("write spec"), "personal task should still be there")
        XCTAssertTrue(titles.contains("milk"), "shared-project task should be unioned in")
    }

    // MARK: - Split write

    func testSaveRoutesSharedTasksToSharedFile() throws {
        let shared = ProjectItem(id: "p_share", name: "shared", icon: "cart",
                                  accent: .orange, isShared: true)
        let personal = ProjectItem(id: "p_personal", name: "personal", icon: "folder",
                                    accent: .blue)

        // Pre-create the shared file so the manager has a key for it.
        _ = try manager.createShared(project: shared, tasks: [])

        let p = makePersistence()
        // First: tell persistence the project is shared so refreshSharedStores opens it.
        p.saveNow(.init(tasks: [], projects: [shared, personal]))

        // Now add one task to the shared project AND one to the personal.
        let sharedTask = TaskItem(list: "p_share", title: "bread", pos: Date())
        let personalTask = TaskItem(list: "p_personal", title: "taxes", pos: Date())
        p.saveNow(.init(tasks: [sharedTask, personalTask], projects: [shared, personal]))

        // Main doc should only carry the personal task.
        let mainAuto = AutomergeStore(data: try Data(contentsOf: mainFile))
        let mainSnap = try mainAuto.snapshot()
        XCTAssertEqual(mainSnap.tasks.map(\.title).sorted(), ["taxes"])

        // Shared file should carry only the shared task.
        let sharedStore = manager.openStore(for: "p_share")!
        let sharedSnap = try sharedStore.readSnapshot()
        XCTAssertEqual(sharedSnap.tasks.map(\.title).sorted(), ["bread"])

        // Union load should show both, with no leakage.
        let union = p.load()!
        XCTAssertEqual(Set(union.tasks.map(\.title)), Set(["bread", "taxes"]))
    }

    func testTaskDeletionRoutedByListId() throws {
        let shared = ProjectItem(id: "p_share", name: "shared", icon: "cart",
                                  accent: .orange, isShared: true)
        let sharedTask = TaskItem(list: "p_share", title: "bread", pos: Date())

        _ = try manager.createShared(project: shared, tasks: [sharedTask])

        let p = makePersistence()
        p.saveNow(.init(tasks: [sharedTask], projects: [shared]))

        // Confirm starting state.
        XCTAssertTrue(p.load()!.tasks.contains { $0.title == "bread" })

        // Delete the shared task — the key→value is taskId→listId, so
        // persistence knows to tombstone in the shared file.
        p.saveNow(.init(tasks: [], projects: [shared]),
                   deletedTaskIds: [sharedTask.id: "p_share"])

        XCTAssertFalse(p.load()!.tasks.contains { $0.title == "bread" })

        // And the shared file's snapshot directly agrees.
        let sharedStore = manager.openStore(for: "p_share")!
        let sharedSnap = try sharedStore.readSnapshot()
        XCTAssertTrue(sharedSnap.tasks.isEmpty)
    }

    // MARK: - Shared store opens lazily

    func testSharedStoreIgnoredWhenNoKey() throws {
        // Main doc has a project flagged shared, but this device has
        // no key for it (never joined). Persistence should just skip
        // that project's file — not crash, not produce phantom tasks.
        let orphan = ProjectItem(id: "p_orphan", name: "orphan", icon: "folder",
                                  accent: .gray, isShared: true)
        let p = makePersistence()
        p.saveNow(.init(tasks: [], projects: [orphan]))
        XCTAssertNotNil(p.load())  // doesn't throw
        XCTAssertEqual(p.load()!.tasks.count, 0)
    }

    // MARK: - Integration: end-to-end promote + add

    func testPromoteThenAddWritesToSharedFile() throws {
        // Simulate TaskStore's flow: promote a project then keep adding
        // tasks. Post-promotion adds must land in the shared file, not
        // the main doc.
        let project = ProjectItem(id: "p_groc", name: "groceries", icon: "cart", accent: .orange)
        let p = makePersistence()
        p.saveNow(.init(tasks: [], projects: [project]))

        // Promote via manager (matches what TaskStore.promoteToShared
        // does internally).
        _ = try manager.createShared(project: project, tasks: [])
        var shared = project
        shared.isShared = true

        // After promotion, a new task arrives for this project.
        let newTask = TaskItem(list: "p_groc", title: "milk", pos: Date())
        p.saveNow(.init(tasks: [newTask], projects: [shared]))

        // Assert: task is in the shared file, NOT in the main doc.
        let mainAuto = AutomergeStore(data: try Data(contentsOf: mainFile))
        let mainSnap = try mainAuto.snapshot()
        XCTAssertFalse(mainSnap.tasks.contains { $0.title == "milk" },
                        "post-promotion writes must NOT land in the main doc")

        let sharedStore = manager.openStore(for: "p_groc")!
        let sharedSnap = try sharedStore.readSnapshot()
        XCTAssertTrue(sharedSnap.tasks.contains { $0.title == "milk" },
                       "post-promotion writes must land in the shared file")
    }
}
