import XCTest
import CryptoKit
@testable import todarchy

/// Phase 5: shared-file conflict copies produced by Dropbox / iCloud /
/// Syncthing when two devices write near-simultaneously. Each copy is
/// a valid encrypted envelope under the same key; we just need to
/// decrypt, merge, and delete.
final class SharedConflictIngestionTests: XCTestCase {
    var tmpDir: URL!
    var projectId: String!
    var key: SymmetricKey!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        projectId = "p_groc"
        key = CryptoBox.generateKey()
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func canonicalURL() -> URL {
        tmpDir.appendingPathComponent(PerProjectStore.filename(for: projectId))
    }

    private func writeConflictCopy(named name: String,
                                    seededWith task: TaskItem) throws {
        let tempURL = tmpDir.appendingPathComponent(name)
        let store = PerProjectStore(fileURL: tempURL, projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try store.save(.init(tasks: [task], project: project))
    }

    // MARK: - Shape recognition

    func testDropboxStyleConflictAbsorbed() throws {
        // Device A writes the canonical.
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(
            tasks: [TaskItem(list: projectId, title: "apples", pos: Date())],
            project: project
        ))

        // Dropbox-shaped conflict copy lands in the folder.
        try writeConflictCopy(
            named: "shared_\(projectId!) (iPhone's conflicted copy 2026-04-20).automerge.enc",
            seededWith: TaskItem(list: projectId, title: "bread", pos: Date())
        )

        let absorbed = a.ingestConflictCopies()
        XCTAssertEqual(absorbed, 1)
        let snap = try a.readSnapshot()
        XCTAssertEqual(Set(snap.tasks.map(\.title)), Set(["apples", "bread"]))

        // Conflict file was removed after merge.
        let survivors = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertEqual(survivors.filter { $0.hasSuffix(".automerge.enc") }.count, 1)
    }

    func testICloudStyleConflictAbsorbed() throws {
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [TaskItem(list: projectId, title: "apples", pos: Date())],
                         project: project))

        try writeConflictCopy(
            named: "shared_\(projectId!) 2.automerge.enc",
            seededWith: TaskItem(list: projectId, title: "bread", pos: Date())
        )

        XCTAssertEqual(a.ingestConflictCopies(), 1)
        let titles = Set(try a.readSnapshot().tasks.map(\.title))
        XCTAssertEqual(titles, Set(["apples", "bread"]))
    }

    func testSyncthingStyleConflictAbsorbed() throws {
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [TaskItem(list: projectId, title: "apples", pos: Date())],
                         project: project))

        try writeConflictCopy(
            named: "shared_\(projectId!).sync-conflict-20260420-123456-XXXX.automerge.enc",
            seededWith: TaskItem(list: projectId, title: "bread", pos: Date())
        )

        XCTAssertEqual(a.ingestConflictCopies(), 1)
        let titles = Set(try a.readSnapshot().tasks.map(\.title))
        XCTAssertEqual(titles, Set(["apples", "bread"]))
    }

    func testMultipleConflictsInOneSweep() throws {
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [TaskItem(list: projectId, title: "apples", pos: Date())],
                         project: project))

        // Two peers both produced conflict copies — different shapes.
        try writeConflictCopy(
            named: "shared_\(projectId!) (macbook's conflicted copy 2026-04-22).automerge.enc",
            seededWith: TaskItem(list: projectId, title: "milk", pos: Date())
        )
        try writeConflictCopy(
            named: "shared_\(projectId!) 3.automerge.enc",
            seededWith: TaskItem(list: projectId, title: "bread", pos: Date())
        )

        XCTAssertEqual(a.ingestConflictCopies(), 2)
        let titles = Set(try a.readSnapshot().tasks.map(\.title))
        XCTAssertEqual(titles, Set(["apples", "milk", "bread"]))
    }

    // MARK: - False-positive guards

    func testUnrelatedSharedFileNotAbsorbed() throws {
        // A neighboring shared file for a DIFFERENT project sitting in
        // the same folder must not be touched — different key, different
        // scope.
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [], project: project))

        let otherKey = CryptoBox.generateKey()
        let otherId = "p_other"
        let otherURL = tmpDir.appendingPathComponent(PerProjectStore.filename(for: otherId))
        let other = PerProjectStore(fileURL: otherURL, projectId: otherId, key: otherKey)
        try other.save(.init(
            tasks: [TaskItem(list: otherId, title: "should not leak", pos: Date())],
            project: ProjectItem(id: otherId, name: "other", icon: "folder",
                                  accent: .blue, isShared: true)
        ))

        // Sweep shouldn't see the other project's file (different id prefix).
        XCTAssertEqual(a.ingestConflictCopies(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path),
                       "unrelated shared file must survive the sweep")
    }

    func testProjectIdPrefixCollisionIgnored() throws {
        // Id substring pitfall: if our id is "p_abc" and there's a
        // file for project "p_abc_extra" in the same folder, the
        // ingest must not confuse them. The separator-after-id
        // requirement keeps them distinct.
        projectId = "p_abc"
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "abc", icon: "folder",
                                   accent: .blue, isShared: true)
        try a.save(.init(tasks: [], project: project))

        // Same key (worst case) but a different project id whose
        // filename starts with ours.
        let neighbor = tmpDir.appendingPathComponent("shared_p_abc_extra.automerge.enc")
        let neighborStore = PerProjectStore(fileURL: neighbor,
                                             projectId: "p_abc_extra", key: key)
        try neighborStore.save(.init(
            tasks: [TaskItem(list: "p_abc_extra", title: "should not leak", pos: Date())],
            project: ProjectItem(id: "p_abc_extra", name: "extra", icon: "folder",
                                  accent: .blue, isShared: true)
        ))

        XCTAssertEqual(a.ingestConflictCopies(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path),
                       "neighboring project with id-prefix overlap must survive")
    }

    func testCanonicalFileNotAbsorbed() throws {
        // The canonical file is this project's own on-disk state —
        // merging it into the live doc would be a no-op, but deleting
        // it afterwards would be catastrophic. Make sure we skip it.
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [TaskItem(list: projectId, title: "apples", pos: Date())],
                         project: project))

        XCTAssertEqual(a.ingestConflictCopies(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL().path))
    }

    // MARK: - Wrong-key conflicts are left on disk

    func testWrongKeyConflictLeftAlone() throws {
        // A conflict copy we can't decrypt isn't ours (maybe a peer
        // with a rotated key, or stale bytes). Merge fails silently
        // and we must NOT delete the file.
        let a = PerProjectStore(fileURL: canonicalURL(), projectId: projectId, key: key)
        let project = ProjectItem(id: projectId, name: "groceries",
                                   icon: "cart", accent: .orange, isShared: true)
        try a.save(.init(tasks: [], project: project))

        // Write a conflict-shaped file with garbage bytes (not our
        // envelope at all).
        let badURL = tmpDir.appendingPathComponent(
            "shared_\(projectId!) (foo's conflicted copy).automerge.enc"
        )
        try Data(repeating: 0xFF, count: 200).write(to: badURL)

        XCTAssertEqual(a.ingestConflictCopies(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: badURL.path),
                       "undecryptable conflict file should NOT be auto-deleted")
    }
}
