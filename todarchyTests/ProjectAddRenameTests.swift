import XCTest
import Automerge
@testable import todarchy

/// Repro tests for the "added project name doesn't persist on macOS"
/// bug. Exercises the same `addProject` → `renameProject` path the
/// `ProjectEditorSheet` calls; if these pass the bug is UI-side
/// (focus, .onSubmit, sheet state), if they fail the data layer is
/// what's broken.
final class ProjectAddRenameTests: XCTestCase {

    // MARK: - In-memory state

    func testAddThenRenameUpdatesStore() throws {
        let store = TaskStore.ephemeral()
        let id = store.addProject(name: "")
        XCTAssertEqual(store.projects.first(where: { $0.id == id })?.name, "")

        store.renameProject(id: id, to: "Groceries")
        XCTAssertEqual(store.projects.first(where: { $0.id == id })?.name, "Groceries")
    }

    func testRenameExistingProjectUpdatesStore() throws {
        let store = TaskStore.ephemeral()
        let id = store.addProject(name: "old name")
        store.renameProject(id: id, to: "new name")
        XCTAssertEqual(store.projects.first(where: { $0.id == id })?.name, "new name")
    }

    // MARK: - Persistence round-trip

    /// Add a project, rename it, then push through AutomergeStore.
    /// Reload the bytes — name should be the renamed value.
    func testRenamePersistsThroughAutomergeRoundTrip() throws {
        let store = AutomergeStore()
        var project = ProjectItem(id: "p_test", name: "",
                                  icon: "folder", accentHex: 0x7AA2F7)
        try store.upsertProject(project)
        XCTAssertEqual(try store.snapshot().projects.first?.name, "")

        project.name = "Groceries"
        try store.upsertProject(project)
        XCTAssertEqual(try store.snapshot().projects.first?.name, "Groceries")

        // Round-trip through bytes.
        let bytes = store.save()
        let reloaded = AutomergeStore(data: bytes)
        XCTAssertEqual(try reloaded.snapshot().projects.first?.name, "Groceries")
    }

    /// readProjects silently `continue`s when the `name` field is
    /// missing (`AutomergeStore.swift:354-357`). Verify a freshly-
    /// created project with empty name is still readable — this is
    /// the state right after `addProject(name: "")` before the user
    /// types anything.
    func testEmptyNameProjectStillReads() throws {
        let store = AutomergeStore()
        let project = ProjectItem(id: "p_test", name: "",
                                  icon: "folder", accentHex: 0x7AA2F7)
        try store.upsertProject(project)
        let snap = try store.snapshot()
        XCTAssertEqual(snap.projects.count, 1, "empty name should not drop the project")
        XCTAssertEqual(snap.projects.first?.name, "")
    }

    // MARK: - Through scheduleSave / Persistence

    /// Add then rename in quick succession (mirroring the
    /// ProjectEditorSheet flow), then flush via Persistence.saveNow
    /// and confirm the doc has the renamed value.
    func testAddThenRenameFlushesRenamedName() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-rename-\(UUID().uuidString).automerge")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let persistence = TaskStorePersistence(fileURL: tmp)
        let store = TaskStore(persistence: persistence)

        let id = store.addProject(name: "")
        store.renameProject(id: id, to: "Groceries")

        // Force the flush (instead of waiting for the 250 ms debounce).
        persistence.saveNow(.init(
            tasks: store.tasks, projects: store.projects, contexts: store.contexts
        ))

        // Read back via a fresh AutomergeStore on the same file.
        let bytes = try Data(contentsOf: tmp)
        let reloaded = AutomergeStore(data: bytes)
        let snap = try reloaded.snapshot()
        let project = snap.projects.first { $0.id == id }
        XCTAssertNotNil(project)
        XCTAssertEqual(project?.name, "Groceries",
                       "Renamed name must survive the save+reload cycle")
    }
}
