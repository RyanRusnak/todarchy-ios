#if os(macOS)
import XCTest

@MainActor
final class DeferNotifierTests: XCTestCase {
    var stateURL: URL!
    var notifier: DeferNotifier!
    var store: TaskStore!

    override func setUp() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-notif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        stateURL = tmpDir.appendingPathComponent("notified.json")
        notifier = DeferNotifier(stateURL: stateURL, onFire: { _ in })
        store = TaskStore.ephemeral()
        store.tasks = TaskStore.demoTasks()
        notifier.attach(store: store)
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
    }

    func testTickSurfacesExpiredDefer() {
        // Pick a task and defer it 1h in the past.
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(-3600))
        let surfaced = notifier.tick()
        XCTAssertTrue(surfaced.contains(where: { $0.id == id }))
    }

    func testTickIgnoresFutureDefer() {
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(3600))
        let surfaced = notifier.tick()
        XCTAssertFalse(surfaced.contains(where: { $0.id == id }))
    }

    func testTickDoesNotReNotifySameTask() {
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(-3600))
        let first = notifier.tick()
        XCTAssertEqual(first.count, 1)
        let second = notifier.tick()
        XCTAssertEqual(second.count, 0)
    }

    func testTickIgnoresDoneTasks() {
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(-3600))
        store.toggleDone(id)
        let surfaced = notifier.tick()
        XCTAssertFalse(surfaced.contains(where: { $0.id == id }))
    }

    func testNotifiedStatePersistsAcrossInstances() {
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(-3600))
        _ = notifier.tick()

        // New notifier reading the same state file should know about this task.
        let replacement = DeferNotifier(stateURL: stateURL, onFire: { _ in })
        replacement.attach(store: store)
        XCTAssertEqual(replacement.tick().count, 0)
    }

    func testStaleIdsArePruned() {
        store.activeSelection = .list("inbox")
        store.selectFirst()
        let id = store.selectedTaskId!
        store.defer_(id, until: Date().addingTimeInterval(-3600))
        _ = notifier.tick()
        XCTAssertEqual(notifier.notifiedCount, 1)

        store.delete(id)
        _ = notifier.tick()
        XCTAssertEqual(notifier.notifiedCount, 0, "Deleted-task id should drop out")
    }
}
#endif
