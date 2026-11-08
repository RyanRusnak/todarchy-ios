import XCTest
import CryptoKit
@testable import todarchy

@MainActor
final class ShareLinkAcceptTests: XCTestCase {
    var tmp: URL!
    var keyStore: InMemoryKeyStore!
    var manager: SharedProjectManager!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        keyStore = InMemoryKeyStore()
        manager = SharedProjectManager(folder: tmp, keyStore: keyStore)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Accept when file is already there

    func testAcceptPullsProjectMetadataFromExistingFile() throws {
        // Device A promotes a project with a specific name/color.
        let project = ProjectItem(id: "p_groc", name: "groceries", icon: "cart", accent: .orange)
        let (_, key) = try manager.createShared(
            project: project,
            tasks: [TaskItem(list: "p_groc", title: "milk", pos: Date())]
        )

        // Device B's TaskStore accepts the link. Since we're simulating
        // "file already delivered", the shared file exists with A's
        // metadata and B should inherit it.
        let store = TaskStore.ephemeral()
        store.projects = []
        store.tasks = []

        let link = ShareLink.encode(projectId: project.id, key: key)
        let added = try store.acceptShareLink(link, manager: manager)

        XCTAssertEqual(added.id, project.id)
        XCTAssertEqual(added.name, "groceries", "metadata must come from the shared file, not a placeholder")
        XCTAssertTrue(added.isShared)
        XCTAssertTrue(store.projects.contains { $0.id == project.id })
        XCTAssertNotNil(keyStore.load(for: project.id), "key must be persisted")
    }

    // MARK: - Accept before the sync daemon has delivered the file

    func testAcceptStubsPlaceholderWhenFileNotYetArrived() throws {
        // Device B arrives *before* Dropbox finishes delivering the
        // encrypted file — the key was saved but there's nothing to
        // read yet. We expect a "shared project" placeholder that'll
        // be overwritten once the file lands.
        let key = CryptoBox.generateKey()
        let payload = ShareLink.Payload(projectId: "p_unborn", key: key)

        let store = TaskStore.ephemeral()
        store.projects = []
        store.tasks = []

        let added = try store.acceptPayload(payload, manager: manager)
        XCTAssertEqual(added.id, "p_unborn")
        XCTAssertTrue(added.isShared)
        XCTAssertEqual(added.name, "shared project",
                        "placeholder name should display until sync delivers the real metadata")
        XCTAssertNotNil(keyStore.load(for: "p_unborn"))
    }

    // MARK: - Idempotence

    func testAcceptIsIdempotent() throws {
        let project = ProjectItem(id: "p_same", name: "shared", icon: "folder", accent: .blue)
        let (_, key) = try manager.createShared(project: project, tasks: [])

        let store = TaskStore.ephemeral()
        store.projects = []
        let link = ShareLink.encode(projectId: project.id, key: key)

        _ = try store.acceptShareLink(link, manager: manager)
        _ = try store.acceptShareLink(link, manager: manager)

        let count = store.projects.filter { $0.id == project.id }.count
        XCTAssertEqual(count, 1, "accepting the same link twice must not duplicate the project")
    }

    func testAcceptPreservesCollidingPrivateListAndUsesSendersMetadata() throws {
        let project = ProjectItem(id: "p_home", name: "Her groceries", icon: "cart", accent: .orange)
        let (_, key) = try manager.createShared(project: project, tasks: [])
        let store = TaskStore.ephemeral()
        store.projects = [ProjectItem(id: project.id, name: "My chores", icon: "house", accent: .blue)]
        let parent = TaskItem(list: project.id, title: "Private parent")
        let child = TaskItem(list: project.id, title: "Private child", parent: parent.id)
        store.tasks = [parent, child]
        store.activeSelection = .list(project.id)
        store.selectedTaskId = child.id

        let added = try store.acceptPayload(.init(projectId: project.id, key: key), manager: manager)

        XCTAssertEqual(added.name, "Her groceries")
        XCTAssertTrue(added.isShared)
        let privateList = try XCTUnwrap(store.projects.first { $0.name == "My chores" })
        XCTAssertNotEqual(privateList.id, project.id)
        XCTAssertFalse(privateList.isShared)
        XCTAssertTrue(store.tasks.allSatisfy { $0.list == privateList.id })
        XCTAssertFalse(store.tasks.contains { $0.id == parent.id || $0.id == child.id })
        let movedParent = try XCTUnwrap(store.tasks.first { $0.title == parent.title })
        let movedChild = try XCTUnwrap(store.tasks.first { $0.title == child.title })
        XCTAssertEqual(movedChild.parent, movedParent.id)
        XCTAssertEqual(store.selectedTaskId, movedChild.id)
        _ = try store.acceptPayload(.init(projectId: project.id, key: key), manager: manager)
        XCTAssertEqual(store.projects.count, 2)
    }

    func testConflictingSharedInvitationDoesNotReplaceExistingKey() throws {
        let project = ProjectItem(id: "p_home", name: "Our shared list", icon: "house", accent: .blue)
        let (_, originalKey) = try manager.createShared(project: project, tasks: [])
        let store = TaskStore.ephemeral()
        var shared = project
        shared.isShared = true
        store.projects = [shared]
        store.tasks = [TaskItem(list: project.id, title: "Keep me")]
        let before = store.tasks

        XCTAssertThrowsError(try store.acceptPayload(.init(projectId: project.id,
                                                          key: CryptoBox.generateKey()), manager: manager)) {
            XCTAssertEqual($0 as? TaskStore.ShareError, .conflictingInvitation)
        }
        XCTAssertEqual(keyStore.load(for: project.id), originalKey)
        XCTAssertEqual(store.tasks, before)
        XCTAssertEqual(store.projects, [shared])
    }

    func testCollisionBeforeDownloadSurvivesFlushAndRestart() throws {
        let persistence = TaskStorePersistence(fileURL: tmp.appendingPathComponent("tasks.automerge"))
        persistence.sharedProjectManager = manager
        let local = ProjectItem(id: "p_home", name: "Private", icon: "house", accent: .blue)
        let task = TaskItem(list: local.id, title: "Keep private")
        persistence.saveNow(.init(tasks: [task], projects: [local]))
        let store = TaskStore(persistence: persistence)
        let key = CryptoBox.generateKey()
        let added = try store.acceptPayload(.init(projectId: local.id, key: key), manager: manager)
        XCTAssertEqual(added.name, "shared project")
        XCTAssertTrue(persistence.syncNow().success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: local.id).path))

        let owner = PerProjectStore(fileURL: tmp.appendingPathComponent("owner.enc"),
                                    projectId: local.id, key: key)
        let remote = ProjectItem(id: local.id, name: "Her groceries", icon: "cart", accent: .orange,
                                 isShared: true)
        // Deterministic starter task ids can collide as well as list ids.
        let remoteTask = TaskItem(id: task.id, list: local.id, title: "Her milk")
        try owner.save(.init(tasks: [remoteTask], project: remote))
        try FileManager.default.copyItem(at: owner.fileURL, to: manager.fileURL(for: local.id))
        XCTAssertTrue(persistence.syncNow().success)
        let restarted = TaskStorePersistence(fileURL: tmp.appendingPathComponent("tasks.automerge"))
        restarted.sharedProjectManager = manager
        let snapshot = try XCTUnwrap(restarted.load())
        XCTAssertEqual(Set(snapshot.tasks.map(\.title)), ["Keep private", "Her milk"])
        XCTAssertEqual(snapshot.projects.first { $0.id == local.id }?.name, remote.name)
        let shared = try XCTUnwrap(manager.openStore(for: local.id))
        XCTAssertEqual(try shared.readSnapshot().tasks.map(\.title), ["Her milk"])
    }

    // MARK: - Error cases

    func testAcceptBadLinkThrows() {
        let store = TaskStore.ephemeral()
        store.projects = []
        let bad = URL(string: "todarchy://share/#k=")!  // missing id, empty key
        XCTAssertThrowsError(try store.acceptShareLink(bad, manager: manager)) { error in
            guard case TaskStore.ShareError.invalidLink = error else {
                return XCTFail("expected .invalidLink, got \(error)")
            }
        }
    }
}
