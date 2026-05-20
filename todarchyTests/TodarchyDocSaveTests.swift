import XCTest

/// Regression tests for `TodarchyDoc.save()` — the MCP server's
/// read-mutate-write cycle. The save path used to overwrite the
/// file with the in-memory doc, ignoring whatever the running app
/// might have written between MCP's initial read and its save.
/// Automerge being a CRDT bounded the damage, but the on-disk
/// state was briefly inconsistent and other readers (peer devices
/// syncing via a folder) could observe the stale snapshot.
///
/// The fix re-reads the file and merges any concurrent changes
/// before writing — same pattern the app's `flushNow` uses.
@MainActor
final class TodarchyDocSaveTests: XCTestCase {
    var tmpURL: URL!

    override func setUp() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-mcp-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        tmpURL = tmpDir.appendingPathComponent("tasks.automerge")
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())
    }

    /// Concurrent-writer race: the app appends a task to the file
    /// between MCP's init and MCP's save. After the fix, MCP's
    /// save merges the app's changes before writing — so the
    /// resulting file contains both writers' tasks.
    func testSave_mergesConcurrentDiskWriteBeforeReplacingFile() throws {
        // Seed an initial state on disk.
        let initial = AutomergeStore()
        try initial.upsertTasks([
            TaskItem(id: "a", list: "inbox", title: "alpha", pos: Date())
        ])
        try Data(initial.save()).write(to: tmpURL)

        // MCP opens the doc (reads disk = state {alpha}).
        let mcp = TodarchyDoc(fileURL: tmpURL)

        // The running app writes a new task to the same file before
        // MCP's save commits.
        let appWriter = AutomergeStore(data: try Data(contentsOf: tmpURL))
        try appWriter.upsertTasks([
            TaskItem(id: "b", list: "inbox", title: "bravo", pos: Date())
        ])
        try Data(appWriter.save()).write(to: tmpURL)

        // MCP performs its tool mutation and saves.
        try mcp.store.upsertTasks([
            TaskItem(id: "c", list: "inbox", title: "charlie", pos: Date())
        ])
        try mcp.save()

        // The file on disk now reflects all three writers — alpha
        // (initial), bravo (app's intervening write), and charlie
        // (MCP's mutation). Without the pre-write merge, bravo would
        // have been stranded in the file MCP never saw.
        let final = AutomergeStore(data: try Data(contentsOf: tmpURL))
        let titles = Set(try final.snapshot().tasks.map(\.title))
        XCTAssertTrue(titles.contains("alpha"), "lost initial state")
        XCTAssertTrue(titles.contains("bravo"),
            "MCP save clobbered an intervening app write — pre-write merge is missing or broken")
        XCTAssertTrue(titles.contains("charlie"), "lost MCP's mutation")
    }

    /// Sanity: no concurrent writer → save just writes MCP's state.
    /// Guards against the pre-write merge accidentally introducing
    /// state from a stale or empty source.
    func testSave_withoutConcurrentWriter_writesMutationsCleanly() throws {
        // No initial file. TodarchyDoc starts with an empty doc.
        let mcp = TodarchyDoc(fileURL: tmpURL)
        try mcp.store.upsertTasks([
            TaskItem(id: "x", list: "inbox", title: "xenon", pos: Date())
        ])
        try mcp.save()

        let final = AutomergeStore(data: try Data(contentsOf: tmpURL))
        let titles = Set(try final.snapshot().tasks.map(\.title))
        XCTAssertEqual(titles, ["xenon"])
    }
}
