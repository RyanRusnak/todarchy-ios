import XCTest
import CryptoKit
@testable import todarchy

final class PerProjectStoreTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-perproject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeProject(id: String = "p_share1", name: String = "groceries") -> ProjectItem {
        ProjectItem(id: id, name: name, icon: "cart.fill", accent: .orange)
    }

    private func makeTask(title: String, list: String) -> TaskItem {
        TaskItem(list: list, title: title, created: Date(), pos: Date())
    }

    private func fileURL(forProject id: String) -> URL {
        tmpDir.appendingPathComponent(PerProjectStore.filename(for: id))
    }

    // MARK: - Round-trip

    func testSaveThenLoadRecoversSnapshot() throws {
        let key = CryptoBox.generateKey()
        let project = makeProject()
        let url = fileURL(forProject: project.id)

        let a = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        try a.save(.init(
            tasks: [
                makeTask(title: "apples", list: project.id),
                makeTask(title: "oatmilk", list: project.id),
            ],
            project: project
        ))

        // Fresh instance, same file + same key — should see the same state.
        let b = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        let loaded = try b.readSnapshot()
        XCTAssertEqual(loaded.project.id, project.id)
        XCTAssertEqual(loaded.project.name, "groceries")
        XCTAssertEqual(Set(loaded.tasks.map(\.title)), Set(["apples", "oatmilk"]))
    }

    func testOnDiskBytesAreEncrypted() throws {
        let key = CryptoBox.generateKey()
        let project = makeProject()
        let url = fileURL(forProject: project.id)

        let store = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        try store.save(.init(
            tasks: [makeTask(title: "very private task title", list: project.id)],
            project: project
        ))

        let onDisk = try Data(contentsOf: url)
        XCTAssertTrue(CryptoBox.isEnvelope(onDisk),
                       "Saved file must begin with the CryptoBox envelope.")
        // Plaintext title must NOT be present in the ciphertext.
        let needle = Data("very private task title".utf8)
        XCTAssertNil(onDisk.range(of: needle),
                      "Task title leaked into the encrypted blob.")
    }

    // MARK: - Wrong key

    func testWrongKeyStartsBlank() throws {
        let rightKey = CryptoBox.generateKey()
        let wrongKey = CryptoBox.generateKey()
        let project = makeProject()
        let url = fileURL(forProject: project.id)

        // Seed the file with the right key.
        let writer = PerProjectStore(fileURL: url, projectId: project.id, key: rightKey)
        try writer.save(.init(tasks: [makeTask(title: "secret", list: project.id)],
                              project: project))

        // Open with the wrong key — initializer silently starts a blank
        // doc because the envelope won't decrypt. readSnapshot() should
        // then fail with `missingProject` because no project was ever
        // upserted into the blank doc.
        let reader = PerProjectStore(fileURL: url, projectId: project.id, key: wrongKey)
        XCTAssertThrowsError(try reader.readSnapshot()) { error in
            XCTAssertEqual(error as? PerProjectStore.StoreError, .missingProject)
        }
    }

    // MARK: - Merge (two-device scenario)

    func testTwoDeviceMerge() throws {
        let key = CryptoBox.generateKey()
        let project = makeProject()

        let urlA = tmpDir.appendingPathComponent("a-\(PerProjectStore.filename(for: project.id))")
        let urlB = tmpDir.appendingPathComponent("b-\(PerProjectStore.filename(for: project.id))")

        // Device A writes "milk".
        let a = PerProjectStore(fileURL: urlA, projectId: project.id, key: key)
        try a.save(.init(tasks: [makeTask(title: "milk", list: project.id)], project: project))

        // Device B independently creates the project and writes "bread".
        let b = PerProjectStore(fileURL: urlB, projectId: project.id, key: key)
        try b.save(.init(tasks: [makeTask(title: "bread", list: project.id)], project: project))

        // A receives B's encrypted bytes over the sync transport.
        let bBytes = try Data(contentsOf: urlB)
        XCTAssertTrue(a.merge(encryptedBytes: bBytes))

        // After the merge, A's in-memory snapshot has both tasks.
        let merged = try a.readSnapshot()
        let titles = Set(merged.tasks.map(\.title))
        XCTAssertEqual(titles, Set(["milk", "bread"]))
    }

    func testMergeWithWrongKeyReturnsFalse() throws {
        let keyA = CryptoBox.generateKey()
        let keyB = CryptoBox.generateKey()
        let project = makeProject()
        let urlA = fileURL(forProject: project.id)
        let urlB = tmpDir.appendingPathComponent("otherB.enc")

        let a = PerProjectStore(fileURL: urlA, projectId: project.id, key: keyA)
        try a.save(.init(tasks: [makeTask(title: "apples", list: project.id)],
                         project: project))

        // B's bytes, encrypted with a totally unrelated key.
        let b = PerProjectStore(fileURL: urlB, projectId: project.id, key: keyB)
        try b.save(.init(tasks: [makeTask(title: "bread", list: project.id)],
                         project: project))
        let bBytes = try Data(contentsOf: urlB)

        // Merging a foreign-key envelope should fail cleanly without
        // crashing or corrupting our live state.
        XCTAssertFalse(a.merge(encryptedBytes: bBytes))
        let snap = try a.readSnapshot()
        XCTAssertEqual(snap.tasks.map(\.title), ["apples"])
    }

    // MARK: - refreshFromDisk

    func testRefreshFromDiskPullsInExternalChanges() throws {
        let key = CryptoBox.generateKey()
        let project = makeProject()
        let url = fileURL(forProject: project.id)

        // Device A creates the file with "apples".
        let a = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        try a.save(.init(tasks: [makeTask(title: "apples", list: project.id)],
                         project: project))

        // Separate writer (simulating Dropbox dropping peer B's bytes
        // into the same path) appends "bread" to a fresh doc and
        // replaces the file.
        let simulated = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        try simulated.save(.init(tasks: [makeTask(title: "bread", list: project.id)],
                                 project: project))

        // A hasn't been told anything changed yet. Pull from disk.
        XCTAssertTrue(a.refreshFromDisk())
        let snap = try a.readSnapshot()
        XCTAssertTrue(snap.tasks.contains(where: { $0.title == "apples" }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.title == "bread" }))
    }

    // MARK: - Filename conventions

    func testFilenameRoundTrip() {
        XCTAssertEqual(PerProjectStore.filename(for: "p_abc123"),
                       "shared_p_abc123.automerge.enc")
        XCTAssertEqual(PerProjectStore.projectId(fromFilename: "shared_p_abc123.automerge.enc"),
                       "p_abc123")
    }

    func testFilenameParseRejectsUnrelatedNames() {
        XCTAssertNil(PerProjectStore.projectId(fromFilename: "tasks.automerge"))
        XCTAssertNil(PerProjectStore.projectId(fromFilename: "shared_.automerge.enc"))
        XCTAssertNil(PerProjectStore.projectId(fromFilename: "random.txt"))
        XCTAssertNil(PerProjectStore.projectId(fromFilename: "shared_foo.automerge"))  // missing .enc
    }

    // MARK: - Deletion tombstones

    func testDeletedTaskIdsRemoveTaskFromSnapshot() throws {
        let key = CryptoBox.generateKey()
        let project = makeProject()
        let url = fileURL(forProject: project.id)

        let store = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        let toKeep = makeTask(title: "keep me", list: project.id)
        let toDelete = makeTask(title: "gone", list: project.id)

        try store.save(.init(tasks: [toKeep, toDelete], project: project))

        // Delete one, save just the survivor.
        try store.save(.init(tasks: [toKeep], project: project),
                       deletedTaskIds: [toDelete.id])

        let reader = PerProjectStore(fileURL: url, projectId: project.id, key: key)
        let snap = try reader.readSnapshot()
        XCTAssertEqual(snap.tasks.map(\.title), ["keep me"])
    }
}
