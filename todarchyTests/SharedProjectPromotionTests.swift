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

        // The UI keeps the union of personal and shared tasks visible.
        let project = store.projects.first(where: { $0.id == pid })
        XCTAssertNotNil(project)
        XCTAssertTrue(project!.isShared)
        XCTAssertTrue(store.tasks.contains(where: { $0.list == pid }))
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

    func testRenamedStarterListsGetDistinctSharedIdentities() throws {
        let other = TaskStore.ephemeral()
        let otherFolder = tmpDir.appendingPathComponent("other")
        let otherManager = SharedProjectManager(folder: otherFolder, keyStore: InMemoryKeyStore())
        for device in [store!, other] {
            device.projects = [ProjectItem(id: "p_home", name: "Renamed list", icon: "cart", accent: .orange)]
            device.tasks = [TaskItem(id: "same-demo-task", list: "p_home", title: "milk")]
            device.activeSelection = .list("p_home")
        }
        let first = try ShareLink.decode(store.promoteToShared("p_home", manager: manager)).get()
        let second = try ShareLink.decode(other.promoteToShared("p_home", manager: otherManager)).get()
        XCTAssertNotEqual(first.projectId, "p_home")
        XCTAssertNotEqual(first.projectId, second.projectId)
        XCTAssertEqual(store.activeSelection, .list(first.projectId))
        XCTAssertNotEqual(store.tasks.first?.id, other.tasks.first?.id)
        let shared = try XCTUnwrap(manager.openStore(for: first.projectId))
        let snapshot = try shared.readSnapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), store.tasks.map(\.id))
        XCTAssertEqual(snapshot.tasks.map(\.list), store.tasks.map(\.list))
        XCTAssertEqual(snapshot.tasks.map(\.title), store.tasks.map(\.title))
        XCTAssertEqual(try shared.readSnapshot().project.name, "Renamed list")
    }

    func testStarterPromotionSurvivesFlushAndRestart() throws {
        let mainFile = tmpDir.appendingPathComponent("tasks.automerge")
        let persistence = TaskStorePersistence(fileURL: mainFile)
        persistence.sharedProjectManager = manager
        let project = ProjectItem(id: "p_home", name: "Groceries", icon: "cart", accent: .orange)
        let milk = TaskItem(list: project.id, title: "milk")
        persistence.saveNow(.init(tasks: [milk], projects: [project]))
        let live = TaskStore(persistence: persistence)
        let payload = try ShareLink.decode(live.promoteToShared(project.id, manager: manager)).get()
        XCTAssertTrue(persistence.syncNow().success)
        let main = AutomergeStore(data: try Data(contentsOf: mainFile))
        XCTAssertTrue(try main.snapshot().tasks.isEmpty)
        XCTAssertEqual(try main.snapshot().projects.map(\.id), [payload.projectId])
        let restarted = TaskStorePersistence(fileURL: mainFile)
        restarted.sharedProjectManager = manager
        XCTAssertEqual(restarted.load()?.tasks.map(\.title), ["milk"])
        XCTAssertEqual(restarted.load()?.projects.map(\.id), [payload.projectId])
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

    func testPromotionSurvivesPersistenceFlushAndRestart() async throws {
        let mainFile = tmpDir.appendingPathComponent("tasks.automerge")
        let persistence = TaskStorePersistence(fileURL: mainFile)
        persistence.sharedProjectManager = manager
        let project = ProjectItem(id: "p_groc", name: "groceries", icon: "cart", accent: .orange)
        let milk = TaskItem(list: project.id, title: "milk", pos: Date())
        persistence.saveNow(.init(tasks: [milk], projects: [project]))
        let live = TaskStore(persistence: persistence)
        _ = try live.promoteToShared(project.id, manager: manager)

        // Flush the actual debounced snapshot, including any delete buffers
        // produced by TaskStore. The old ephemeral-only tests missed this.
        XCTAssertTrue(persistence.syncNow().success)
        let shared = try XCTUnwrap(manager.openStore(for: project.id))
        XCTAssertEqual(try shared.readSnapshot().tasks.map(\.id), [milk.id])
        let main = AutomergeStore(data: try Data(contentsOf: mainFile))
        XCTAssertTrue(try main.snapshot().tasks.isEmpty)
        let restarted = TaskStorePersistence(fileURL: mainFile)
        restarted.sharedProjectManager = manager
        XCTAssertEqual(restarted.load()?.tasks.map(\.id), [milk.id])
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
