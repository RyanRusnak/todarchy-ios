import XCTest
import CryptoKit
@testable import todarchy

@MainActor
final class SharedProjectPromotionTests: XCTestCase {
    var tmpDir: URL!
    var store: TaskStore!
    var keyStore: InMemoryKeyStore!
    var manager: SharedProjectManager!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = TaskStore.ephemeral()
        store.tasks = []
        store.projects = []
        keyStore = InMemoryKeyStore()
        manager = SharedProjectManager(folder: tmpDir, keyStore: keyStore)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Happy path

    func testPromoteMovesTasksToEncryptedFile() throws {
        // Set up: one local project with three tasks.
        let pid = "p_groceries"
        store.projects = [ProjectItem(id: pid, name: "groceries", icon: "cart", accent: .orange)]
        store.tasks = [
            TaskItem(list: pid, title: "milk", pos: Date()),
            TaskItem(list: pid, title: "bread", pos: Date()),
            TaskItem(list: pid, title: "eggs", pos: Date()),
            TaskItem(list: "inbox", title: "unrelated", pos: Date()),
        ]

        let shareURL = try store.promoteToShared(pid, manager: manager)

        // Link format check.
        XCTAssertEqual(shareURL.scheme, "todarchy")
        XCTAssertEqual(shareURL.host, "share")
        XCTAssertTrue(shareURL.path.hasSuffix(pid))
        XCTAssertNotNil(shareURL.fragment)

        // Key is in the key store.
        XCTAssertNotNil(keyStore.load(for: pid))

        // Encrypted file exists.
        let fileURL = manager.fileURL(for: pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let bytes = try Data(contentsOf: fileURL)
        XCTAssertTrue(CryptoBox.isEnvelope(bytes))

        // Main doc: project still present, but flagged shared; its
        // tasks have been removed. Unrelated tasks untouched.
        let project = store.projects.first(where: { $0.id == pid })
        XCTAssertNotNil(project)
        XCTAssertTrue(project!.isShared)
        XCTAssertFalse(store.tasks.contains(where: { $0.list == pid }))
        XCTAssertTrue(store.tasks.contains(where: { $0.title == "unrelated" }))
    }

    func testSharedFileContainsOriginalTasks() throws {
        let pid = "p_groceries"
        store.projects = [ProjectItem(id: pid, name: "groceries", icon: "cart", accent: .orange)]
        let milk = TaskItem(list: pid, title: "milk", pos: Date())
        let bread = TaskItem(list: pid, title: "bread", pos: Date())
        store.tasks = [milk, bread]

        let shareURL = try store.promoteToShared(pid, manager: manager)

        // Decode the link, open the shared store with the key, verify
        // tasks round-tripped intact.
        let payload = try ShareLink.decode(shareURL).get()
        let sharedStore = manager.openStore(for: payload.projectId)
        XCTAssertNotNil(sharedStore)
        let snap = try sharedStore!.readSnapshot()
        XCTAssertEqual(Set(snap.tasks.map(\.title)), Set(["milk", "bread"]))
        XCTAssertEqual(snap.project.id, pid)
        XCTAssertTrue(snap.project.isShared)
    }

    func testPromoteGeneratesValidShareLink() throws {
        let pid = "p_abc"
        store.projects = [ProjectItem(id: pid, name: "abc", icon: "folder", accent: .blue)]

        let shareURL = try store.promoteToShared(pid, manager: manager)
        let payload = try ShareLink.decode(shareURL).get()
        XCTAssertEqual(payload.projectId, pid)

        // Key from link should decrypt the shared file.
        let bytes = try Data(contentsOf: manager.fileURL(for: pid))
        XCTAssertNoThrow(try CryptoBox.open(bytes, with: payload.key))
    }

    // MARK: - Guards

    func testPromoteUnknownProjectThrows() {
        XCTAssertThrowsError(try store.promoteToShared("p_does_not_exist", manager: manager)) { error in
            XCTAssertEqual(error as? TaskStore.ShareError, .projectNotFound)
        }
    }

    func testPromoteInboxThrows() {
        store.projects = [ProjectItem(id: "inbox", name: "inbox", icon: "tray", accent: .orange, isInbox: true)]
        XCTAssertThrowsError(try store.promoteToShared("inbox", manager: manager)) { error in
            XCTAssertEqual(error as? TaskStore.ShareError, .inboxNotShareable)
        }
    }

    func testPromoteAlreadySharedThrows() throws {
        let pid = "p_once"
        store.projects = [ProjectItem(id: pid, name: "already", icon: "folder",
                                       accent: .blue, isShared: true)]
        XCTAssertThrowsError(try store.promoteToShared(pid, manager: manager)) { error in
            XCTAssertEqual(error as? TaskStore.ShareError, .alreadyShared)
        }
    }

    // MARK: - Undo

    func testPromoteIsOneUndoUnit() throws {
        let pid = "p_x"
        store.projects = [ProjectItem(id: pid, name: "x", icon: "folder", accent: .blue)]
        let t1 = TaskItem(list: pid, title: "a", pos: Date())
        let t2 = TaskItem(list: pid, title: "b", pos: Date())
        store.tasks = [t1, t2]

        _ = try store.promoteToShared(pid, manager: manager)
        XCTAssertFalse(store.tasks.contains(where: { $0.list == pid }))

        // Undo restores the original task set. The shared file / key
        // still exist — undo doesn't reach through the file system —
        // but the TaskStore's in-memory state is back to pre-promotion.
        XCTAssertTrue(store.undo())
        XCTAssertEqual(Set(store.tasks.filter { $0.list == pid }.map(\.title)),
                       Set(["a", "b"]))
    }

    // MARK: - Join-from-link path

    func testAcceptFromShareLinkStoresKey() throws {
        // User A promotes.
        let pid = "p_groc"
        store.projects = [ProjectItem(id: pid, name: "g", icon: "cart", accent: .orange)]
        store.tasks = [TaskItem(list: pid, title: "milk", pos: Date())]
        let shareURL = try store.promoteToShared(pid, manager: manager)

        // User B — fresh device, fresh key store, same sync folder
        // (simulated by the same tmpDir).
        let otherKeyStore = InMemoryKeyStore()
        let otherManager = SharedProjectManager(folder: tmpDir, keyStore: otherKeyStore)
        let payload = try ShareLink.decode(shareURL).get()
        let sharedStore = try otherManager.accept(payload: payload)

        // The key is registered locally for them now.
        XCTAssertNotNil(otherKeyStore.load(for: pid))

        // Because the encrypted file sits in the shared tmp folder
        // (what real Dropbox would give them), reading the snapshot
        // surfaces A's tasks.
        let snap = try sharedStore.readSnapshot()
        XCTAssertEqual(snap.tasks.first?.title, "milk")
    }

    // MARK: - Directory scan

    func testKnownSharedProjectIdsListsFiles() throws {
        let pid1 = "p_one"
        let pid2 = "p_two"
        store.projects = [
            ProjectItem(id: pid1, name: "one", icon: "folder", accent: .blue),
            ProjectItem(id: pid2, name: "two", icon: "folder", accent: .blue),
        ]
        _ = try store.promoteToShared(pid1, manager: manager)
        _ = try store.promoteToShared(pid2, manager: manager)

        XCTAssertEqual(Set(manager.knownSharedProjectIds()), Set([pid1, pid2]))
    }
}
