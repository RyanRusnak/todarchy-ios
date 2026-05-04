import XCTest
@testable import todarchy

@MainActor
final class ContextStoreTests: XCTestCase {
    var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore(persistence: nil)
        store.tasks = []
        // Fresh in-memory store seeds from TaskContext.allCases.
    }

    // MARK: - Built-in seed

    func testFreshStoreSeedsBuiltInContexts() {
        XCTAssertEqual(store.contexts, TaskContext.allCases)
    }

    // MARK: - addContext

    func testAddContextNormalizesAndAppends() {
        let ctx = store.addContext("Grocery")
        XCTAssertEqual(ctx, TaskContext(rawValue: "@grocery"))
        XCTAssertTrue(store.contexts.contains(TaskContext(rawValue: "@grocery")))
    }

    func testAddContextIsIdempotent() {
        let countBefore = store.contexts.count
        _ = store.addContext("home")
        XCTAssertEqual(store.contexts.count, countBefore,
                       "Re-adding @home should be a no-op since it's a built-in.")
    }

    func testAddContextRejectsEmptyAndPunctuationOnly() {
        XCTAssertNil(store.addContext(""))
        XCTAssertNil(store.addContext("   "))
        XCTAssertNil(store.addContext("@"))
    }

    // MARK: - removeContext

    func testRemoveContextDropsFromList() {
        let custom = store.addContext("gym")!
        XCTAssertTrue(store.contexts.contains(custom))
        store.removeContext(custom)
        XCTAssertFalse(store.contexts.contains(custom))
    }

    func testRemoveContextLeavesTaskCtxIntact() {
        // Tasks keep their raw ctx string so the chip still renders even
        // after the context is removed from the editable list.
        let ctx = store.addContext("gym")!
        let id = store.add(raw: "lift @gym", list: "inbox")!
        store.removeContext(ctx)
        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.ctx, ctx,
                       "Removing a context must not mutate task.ctx values.")
    }

    func testRemoveContextClearsActiveFilterIfMatching() {
        let custom = store.addContext("gym")!
        store.activeContextFilter = custom
        store.removeContext(custom)
        XCTAssertNil(store.activeContextFilter)
    }

    // MARK: - renameContext

    func testRenameContextUpdatesListAndTasks() {
        let from = store.addContext("gym")!
        let id = store.add(raw: "lift @gym", list: "inbox")!
        XCTAssertTrue(store.renameContext(from: from, to: "fitness"))

        let to = TaskContext(rawValue: "@fitness")
        XCTAssertTrue(store.contexts.contains(to))
        XCTAssertFalse(store.contexts.contains(from))
        XCTAssertEqual(store.tasks.first { $0.id == id }?.ctx, to)
    }

    func testRenameContextRefusesCollision() {
        let gym = store.addContext("gym")!
        // @work already exists as a built-in.
        XCTAssertFalse(store.renameContext(from: gym, to: "work"),
                       "Rename to an existing context must fail rather than merge silently.")
        XCTAssertTrue(store.contexts.contains(gym))
    }

    // MARK: - Auto-discovery via parser

    func testQuickAddAutoRegistersUnknownContext() {
        let id = store.add(raw: "buy bread @grocery", list: "inbox")!
        let ctx = TaskContext(rawValue: "@grocery")
        XCTAssertTrue(store.contexts.contains(ctx),
                       "A new @token in quick-add input should appear in the contexts list.")
        XCTAssertEqual(store.tasks.first { $0.id == id }?.ctx, ctx)
    }

    func testQuickAddDoesntDuplicateExistingContext() {
        let countBefore = store.contexts.count
        _ = store.add(raw: "do thing @work", list: "inbox")
        XCTAssertEqual(store.contexts.count, countBefore)
    }
}
