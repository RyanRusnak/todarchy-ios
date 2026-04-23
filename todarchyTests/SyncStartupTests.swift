import XCTest

@MainActor
final class SyncStartupTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    /// THE critical regression: picking a sync folder must re-point the
    /// persistence at the sync file. Without this, every save goes to
    /// Application Support and the Dropbox file never changes.
    func testSetFolderRepointsPersistence() throws {
        // Start a persistence at a "default" location.
        let defaultURL = tmpDir.appendingPathComponent("default.automerge")
        let persistence = TaskStorePersistence(fileURL: defaultURL)
        XCTAssertEqual(persistence.fileURL, defaultURL)

        // Pick a sync folder.
        let syncFolder = tmpDir.appendingPathComponent("Dropbox/todarchy_sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        try persistence.setFileURL(syncFolder.appendingPathComponent("tasks.automerge"))

        XCTAssertEqual(persistence.fileURL.lastPathComponent, "tasks.automerge")
        XCTAssertEqual(persistence.fileURL.deletingLastPathComponent().path, syncFolder.path)
    }

    /// Writes made after the re-point must go to the sync folder, not the
    /// default location.
    func testWritesLandInSyncFolderAfterSetFileURL() throws {
        let defaultURL = tmpDir.appendingPathComponent("default.automerge")
        let syncURL = tmpDir.appendingPathComponent("sync/tasks.automerge")
        try FileManager.default.createDirectory(at: syncURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let persistence = TaskStorePersistence(fileURL: defaultURL)
        try persistence.setFileURL(syncURL)

        persistence.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "should land in sync", pos: Date())],
            projects: []
        ))

        // Read the sync file directly — the task must be there.
        let bytes = try Data(contentsOf: syncURL)
        let store = AutomergeStore(data: bytes)
        let titles = try store.snapshot().tasks.map(\.title)
        XCTAssertTrue(titles.contains("should land in sync"),
                       "saveNow after setFileURL must write to the sync folder, not the default path")

        // And the default file should NOT contain this task (it was written
        // by init but without the user's task).
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            let defaultBytes = try Data(contentsOf: defaultURL)
            let defaultTitles = try AutomergeStore(data: defaultBytes).snapshot().tasks.map(\.title)
            XCTAssertFalse(defaultTitles.contains("should land in sync"),
                            "Task must not be written to the old path after re-point")
        }
    }

    /// File mtime increases when syncNow writes.
    func testSyncNowBumpsFileMtime() throws {
        let syncURL = tmpDir.appendingPathComponent("sync.automerge")
        let persistence = TaskStorePersistence(fileURL: syncURL)

        persistence.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "x", pos: Date())],
            projects: []
        ))
        let mtime1 = try FileManager.default
            .attributesOfItem(atPath: syncURL.path)[.modificationDate] as! Date

        // Ensure at least a millisecond elapses.
        Thread.sleep(forTimeInterval: 0.05)

        _ = persistence.syncNow()
        let mtime2 = try FileManager.default
            .attributesOfItem(atPath: syncURL.path)[.modificationDate] as! Date

        XCTAssertGreaterThan(mtime2, mtime1,
                              "syncNow must write to disk — mtime should advance")
    }
}
