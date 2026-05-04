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

    func testAcceptFlipsSharedFlagOnExistingProject() throws {
        // Edge case: somehow the user has a local project with the
        // same id (unlikely but possible with custom ids). Accepting
        // a link for it should at least flag it as shared, not ignore.
        let project = ProjectItem(id: "p_local", name: "local", icon: "folder", accent: .blue)
        _ = try manager.createShared(project: project, tasks: [])
        let key = keyStore.load(for: project.id)!

        let store = TaskStore.ephemeral()
        store.projects = [project]  // locally present, not yet shared
        XCTAssertFalse(store.projects[0].isShared)

        let link = ShareLink.encode(projectId: project.id, key: key)
        _ = try store.acceptShareLink(link, manager: manager)

        XCTAssertTrue(store.projects.first(where: { $0.id == project.id })!.isShared)
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
