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

    // MARK: - contextsByUsage (quick-add ordering)

    func testContextsByUsageOrdersMostUsedFirst() {
        // Register three contexts; give them different usage counts.
        let work = store.addContext("work")!
        let home = store.addContext("home")!
        let gym = store.addContext("gym")!
        store.tasks = [
            TaskItem(list: "inbox", title: "a", ctx: work),
            TaskItem(list: "inbox", title: "b", ctx: work),
            TaskItem(list: "inbox", title: "c", ctx: work),
            TaskItem(list: "inbox", title: "d", ctx: home),
            TaskItem(list: "inbox", title: "e", ctx: gym),
            TaskItem(list: "inbox", title: "f", ctx: gym),
        ]
        let ordered = store.contextsByUsage
        // work (3) before gym (2) before home (1).
        let iWork = ordered.firstIndex(of: work)!
        let iGym = ordered.firstIndex(of: gym)!
        let iHome = ordered.firstIndex(of: home)!
        XCTAssertLessThan(iWork, iGym)
        XCTAssertLessThan(iGym, iHome)
    }

    func testContextsByUsageSinksUnusedBehindUsed() {
        let gym = store.addContext("gym")!
        store.tasks = [TaskItem(list: "inbox", title: "lift", ctx: gym)]
        let ordered = store.contextsByUsage
        // The one used context should come first, ahead of every never-used
        // built-in default.
        XCTAssertEqual(ordered.first, gym)
        XCTAssertEqual(Set(ordered), Set(store.contexts),
                       "Ordering is a pure permutation — no contexts added or dropped.")
    }

    func testContextsByUsageIsStableWithNoUsage() {
        // With no tasks, ordering must equal the persisted order (stable).
        store.tasks = []
        XCTAssertEqual(store.contextsByUsage, store.contexts)
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

    // MARK: - Adoption of contexts arriving on synced tasks
    //
    // Quick-add registers the `@token` it parses, but tasks authored
    // elsewhere — the Linux app, the web app, the MCP server — never go
    // through that path, so their contexts were invisible on this machine
    // and the chip lists drifted apart. Adoption makes the list a function
    // of the doc instead of of where a task happened to be typed.

    func testAdoptsContextArrivingOnATask() {
        store.tasks = [TaskItem(list: "inbox", title: "ssh in",
                                ctx: TaskContext(rawValue: "@linuxbox"))]
        XCTAssertEqual(store.adoptContextsFromTasks(), [TaskContext(rawValue: "@linuxbox")])
        XCTAssertTrue(store.contexts.contains(TaskContext(rawValue: "@linuxbox")))
    }

    func testAdoptionAppendsInASortedOrderAndIsIdempotent() {
        store.tasks = [
            TaskItem(list: "inbox", title: "a", ctx: TaskContext(rawValue: "@zed")),
            TaskItem(list: "inbox", title: "b", ctx: TaskContext(rawValue: "@alpha")),
            TaskItem(list: "inbox", title: "c", ctx: .work),
        ]
        XCTAssertEqual(store.adoptContextsFromTasks().map(\.rawValue), ["@alpha", "@zed"],
                       "Deterministic order so two machines adopting the same batch converge on the same list.")
        XCTAssertTrue(store.adoptContextsFromTasks().isEmpty,
                      "Nothing left to adopt on a second pass.")
    }

    func testAdoptionDoesNotResurrectARemovedContext() {
        let gym = store.addContext("gym")!
        store.tasks = [TaskItem(list: "inbox", title: "lift", ctx: gym)]
        store.removeContext(gym)
        XCTAssertEqual(store.adoptContextsFromTasks(), [])
        XCTAssertFalse(store.contexts.contains(gym),
                       "A deliberate removal has to outlive adoption, even while tasks still carry the context.")
        XCTAssertTrue(store.retiredContexts.contains(gym))
    }

    func testReAddingARemovedContextUnretiresIt() {
        let gym = store.addContext("gym")!
        store.tasks = [TaskItem(list: "inbox", title: "lift", ctx: gym)]
        store.removeContext(gym)

        XCTAssertEqual(store.addContext("gym"), gym)
        XCTAssertTrue(store.contexts.contains(gym))
        XCTAssertFalse(store.retiredContexts.contains(gym))
        XCTAssertTrue(store.adoptContextsFromTasks().isEmpty)
        XCTAssertTrue(store.contexts.contains(gym),
                      "Once un-retired the context stays put.")
    }

    func testRenameUnretiresTheTargetName() {
        let gym = store.addContext("gym")!
        store.removeContext(gym)
        let fitness = store.addContext("fitness")!
        XCTAssertTrue(store.renameContext(from: fitness, to: "gym"))
        XCTAssertFalse(store.retiredContexts.contains(gym),
                       "Renaming onto a retired name is a deliberate re-introduction.")
    }
}

/// Adoption has to round-trip through the Automerge doc, or the retirement
/// list would only hold until the next launch.
@MainActor
final class ContextAdoptionPersistenceTests: XCTestCase {
    var tmpURL: URL!

    override func setUp() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-ctxadopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        tmpURL = tmpDir.appendingPathComponent("tasks.automerge")
    }

    override func tearDown() async throws {
        _ = try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())
    }

    func testLaunchAdoptsAContextThatOnlyExistsOnTasks() {
        let p = TaskStorePersistence(fileURL: tmpURL)
        // A doc as a peer would leave it: the task carries @server, but the
        // contexts list was never told about it.
        p.saveNow(.init(
            tasks: [TaskItem(list: "inbox", title: "deploy",
                             ctx: TaskContext(rawValue: "@server"), pos: Date())],
            projects: [],
            contexts: TaskContext.allCases
        ))

        let store = TaskStore(persistence: p)
        XCTAssertTrue(store.contexts.contains(TaskContext(rawValue: "@server")),
                      "A context that only exists on incoming tasks should join the list at launch.")
    }

    func testRemovalSurvivesAReload() {
        let p = TaskStorePersistence(fileURL: tmpURL)
        let store = TaskStore(persistence: p)
        let gym = store.addContext("gym")!
        _ = store.add(raw: "lift @gym", list: "inbox")
        store.removeContext(gym)
        p.saveNow(.init(tasks: store.tasks, projects: store.projects,
                        contexts: store.contexts, retiredContexts: store.retiredContexts))

        let reopened = TaskStore(persistence: p)
        XCTAssertTrue(reopened.retiredContexts.contains(gym))
        XCTAssertFalse(reopened.contexts.contains(gym),
                       "Adoption at launch must not undo the removal.")
    }
}
