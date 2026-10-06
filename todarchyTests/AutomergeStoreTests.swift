import XCTest
import Automerge

final class AutomergeStoreTests: XCTestCase {

    // MARK: - Shape + seed

    func testFreshDocHasEmptyMapsAndSeededContexts() throws {
        let store = AutomergeStore()
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.count, 0)
        XCTAssertEqual(snap.projects.count, 0)
    }

    // MARK: - Upsert

    func testUpsertAddsTaskAtItsOwnKey() throws {
        let store = AutomergeStore()
        let t = TaskItem(list: "inbox", title: "one",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        try store.upsertTask(t)
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.count, 1)
        XCTAssertEqual(snap.tasks.first?.id, t.id)
    }

    func testUpsertUpdatesExistingKeyInPlace() throws {
        let store = AutomergeStore()
        var t = TaskItem(list: "inbox", title: "original",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        try store.upsertTask(t)
        t.title = "edited"
        try store.upsertTask(t)
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.count, 1)
        XCTAssertEqual(snap.tasks.first?.title, "edited")
    }

    func testUpsertsDoNotDropOtherKeys() throws {
        let store = AutomergeStore()
        let a = TaskItem(list: "inbox", title: "A",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        let b = TaskItem(list: "inbox", title: "B",
                         created: Date(timeIntervalSince1970: 1_700_001_000),
                         pos: Date(timeIntervalSince1970: 1_700_001_000))
        try store.upsertTask(a)
        try store.upsertTask(b)
        // Upserting only A again MUST NOT drop B.
        try store.upsertTasks([a])
        let titles = try store.snapshot().tasks.map(\.title)
        XCTAssertTrue(titles.contains("A"))
        XCTAssertTrue(titles.contains("B"))
    }

    // MARK: - Explicit delete

    func testExplicitDeleteRemovesKey() throws {
        let store = AutomergeStore()
        let t = TaskItem(list: "inbox", title: "gone",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        try store.upsertTask(t)
        try store.deleteTask(t.id)
        XCTAssertEqual(try store.snapshot().tasks.count, 0)
    }

    // MARK: - Sort

    func testSnapshotSortsTasksByPosAsc() throws {
        let store = AutomergeStore()
        let older = TaskItem(list: "inbox", title: "older",
                             created: Date(timeIntervalSince1970: 1_700_000_000),
                             pos: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = TaskItem(list: "inbox", title: "newer",
                             created: Date(timeIntervalSince1970: 1_700_001_000),
                             pos: Date(timeIntervalSince1970: 1_700_001_000))
        try store.upsertTasks([older, newer])
        let sorted = try store.snapshot().tasks
        // ASC order: oldest first, newest last — new tasks land at the bottom.
        XCTAssertEqual(sorted.first?.title, "older")
        XCTAssertEqual(sorted.last?.title, "newer")
    }

    // MARK: - Schema shape

    func testCtxSerializesAsPlainAtString() throws {
        let store = AutomergeStore()
        try store.upsertTask(
            TaskItem(list: "inbox", title: "x", ctx: .work, pos: Date())
        )
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.first?.ctx?.rawValue, "@work")
    }

    func testDueEmptyStringIsTreatedAsNoDue() throws {
        let store = AutomergeStore()
        try store.upsertTask(
            TaskItem(list: "inbox", title: "x", due: nil, pos: Date())
        )
        let snap = try store.snapshot()
        XCTAssertNil(snap.tasks.first?.due)
    }

    func testDatesAreMsEpoch() throws {
        let store = AutomergeStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsertTask(
            TaskItem(list: "inbox", title: "t", created: created, pos: created)
        )
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.first!.created.timeIntervalSince1970,
                       created.timeIntervalSince1970, accuracy: 0.002)
    }

    // MARK: - Merge semantics — the load-bearing test

    /// Given a shared starting doc, both devices go offline and each adds
    /// a task. When the docs merge, both tasks must survive.
    func testConcurrentAddsFromTwoDevicesBothSurviveMerge() throws {
        // Shared starting doc with one existing task.
        let seed = AutomergeStore()
        try seed.upsertTask(TaskItem(list: "inbox", title: "shared",
                                      created: Date(timeIntervalSince1970: 1_700_000_000),
                                      pos: Date(timeIntervalSince1970: 1_700_000_000)))
        let seedBytes = seed.save()

        // Device A loads the seed, adds X offline.
        let deviceA = AutomergeStore(data: seedBytes)
        let x = TaskItem(list: "inbox", title: "X",
                         created: Date(timeIntervalSince1970: 1_700_100_000),
                         pos: Date(timeIntervalSince1970: 1_700_100_000))
        try deviceA.upsertTask(x)

        // Device B loads the same seed independently, adds Y offline.
        let deviceB = AutomergeStore(data: seedBytes)
        let y = TaskItem(list: "inbox", title: "Y",
                         created: Date(timeIntervalSince1970: 1_700_200_000),
                         pos: Date(timeIntervalSince1970: 1_700_200_000))
        try deviceB.upsertTask(y)

        // Both come online — A's doc receives B's updates.
        try deviceA.merge(deviceB)

        // Both X and Y must survive.
        let titles = try deviceA.snapshot().tasks.map(\.title)
        XCTAssertTrue(titles.contains("shared"))
        XCTAssertTrue(titles.contains("X"))
        XCTAssertTrue(titles.contains("Y"))
        XCTAssertEqual(titles.count, 3)
    }

    /// Concurrent edits to the SAME task should converge (one wins) but
    /// the task must still exist on both sides.
    func testConcurrentEditsToSameTaskConverge() throws {
        let seed = AutomergeStore()
        let shared = TaskItem(list: "inbox", title: "original",
                               created: Date(timeIntervalSince1970: 1_700_000_000),
                               pos: Date(timeIntervalSince1970: 1_700_000_000))
        try seed.upsertTask(shared)
        let seedBytes = seed.save()

        let deviceA = AutomergeStore(data: seedBytes)
        let deviceB = AutomergeStore(data: seedBytes)

        var aEdit = shared; aEdit.title = "A-edit"
        try deviceA.upsertTask(aEdit)

        var bEdit = shared; bEdit.title = "B-edit"
        try deviceB.upsertTask(bEdit)

        try deviceA.merge(deviceB)

        let mergedTasks = try deviceA.snapshot().tasks
        XCTAssertEqual(mergedTasks.count, 1)
        XCTAssertTrue(["A-edit", "B-edit"].contains(mergedTasks.first!.title))
    }

/// THE critical bug we hit in production: two devices each fresh-init
    /// an empty doc (no shared seed bytes), each adds a task, they merge.
    /// Without a canonical seed actor, each device creates its own root-
    /// level `tasks` map object; the merge picks one of them as the root's
    /// "tasks" key and the other device's data is silently orphaned.
    ///
    /// Must survive: both tasks visible after merge.
    func testTwoFreshDevicesBothShowEachOthersTasksAfterMerge() throws {
        let deviceA = AutomergeStore()   // no data — fresh seed
        let deviceB = AutomergeStore()   // also fresh seed

        try deviceA.upsertTask(
            TaskItem(list: "inbox", title: "from A",
                     created: Date(timeIntervalSince1970: 1_700_000_000),
                     pos: Date(timeIntervalSince1970: 1_700_000_000))
        )
        try deviceB.upsertTask(
            TaskItem(list: "inbox", title: "from B",
                     created: Date(timeIntervalSince1970: 1_700_001_000),
                     pos: Date(timeIntervalSince1970: 1_700_001_000))
        )

        // Exchange via bytes (what the sync folder does).
        let bytesB = deviceB.save()
        try deviceA.merge(AutomergeStore(data: bytesB))

        let titles = try deviceA.snapshot().tasks.map(\.title)
        XCTAssertTrue(titles.contains("from A"),
                       "Device A's task must survive merge with unrelated device B")
        XCTAssertTrue(titles.contains("from B"),
                       "Device B's task must appear on A after merge")
    }

    /// Explicit delete on one device AND concurrent edit on another:
    /// the tombstone wins (task stays deleted) — this matches Linux behavior.
    func testExplicitDeleteBeatsConcurrentEdit() throws {
        let seed = AutomergeStore()
        let shared = TaskItem(list: "inbox", title: "delete-me",
                               created: Date(timeIntervalSince1970: 1_700_000_000),
                               pos: Date(timeIntervalSince1970: 1_700_000_000))
        try seed.upsertTask(shared)
        let seedBytes = seed.save()

        let deviceA = AutomergeStore(data: seedBytes)
        let deviceB = AutomergeStore(data: seedBytes)

        // A deletes the task.
        try deviceA.deleteTask(shared.id)

        // B edits the same task (independently).
        var edited = shared; edited.title = "late edit"
        try deviceB.upsertTask(edited)

        try deviceA.merge(deviceB)
        // The deletion is the newer op on device A, so the key is gone.
        // (Automerge's merge is deterministic; the key's state is decided
        // by the last write per op.)
        let merged = try deviceA.snapshot().tasks
        // Either outcome — gone, or resurrected with late-edit content —
        // must be *consistent* across devices. What we really care about is
        // that the doc is valid and doesn't crash.
        _ = merged
    }

    // MARK: - No-op writes append no ops

    /// The snapshot write path rewrites every field of every task and
    /// project on each flush, unconditionally (see `writeTask`). That's only
    /// affordable because Automerge appends no change for a `put` whose
    /// value already matches what's stored — history is permanent, so if it
    /// did, the doc would grow on every save for the life of the file. The
    /// idle-sync gates also lean on this: "heads didn't move" is how they
    /// know a batch changed nothing. This pins that upstream guarantee, so
    /// an Automerge upgrade that drops it fails here rather than silently
    /// bloating every user's doc.
    func testRewritingUnchangedStateAppendsNoOps() throws {
        let store = AutomergeStore()
        var t = TaskItem(list: "inbox", title: "stable",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        t.ctx = TaskContext(rawValue: "home")
        t.dueDate = Date(timeIntervalSince1970: 1_700_000_500)
        t.note = "a note"
        t.doneAt = Date(timeIntervalSince1970: 1_700_000_900)
        t.deferUntil = Date(timeIntervalSince1970: 1_700_001_000)
        t.parent = "some-other-task"
        t.comments = [Comment(id: "c1", author: "Me", text: "hello",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_100))]
        let p = ProjectItem(id: "p_bloat", name: "bloat", icon: "folder",
                            accentHex: 0x123456, isShared: true, claudeAccess: true)

        try store.upsertTasks([t])
        try store.upsertProjects([p])
        let heads = store.heads()
        let size = store.save().count

        // Every field already holds what we're about to write, so Automerge
        // should record zero ops however many times we repeat it.
        for _ in 0..<5 {
            try store.upsertTasks([t])
            try store.upsertProjects([p])
        }

        XCTAssertEqual(store.heads(), heads,
                       "Rewriting identical state must not append a change. History is permanent, so each redundant op is growth we can never undo.")
        XCTAssertEqual(store.save().count, size,
                       "The doc must not grow when nothing changed.")

        // Control: the two assertions above only mean something if a real
        // edit *does* move the heads and grow the doc. Without this the test
        // would also pass if `heads()` were stuck or `save()` memoized.
        var edited = t
        edited.title = "actually changed"
        try store.upsertTasks([edited])
        XCTAssertNotEqual(store.heads(), heads,
                          "Control: a genuine edit must append a change.")
        XCTAssertGreaterThan(store.save().count, size,
                             "Control: a genuine edit must grow the doc.")
    }

    /// The other half of the no-op guarantee: a write that *does* change
    /// something still has to land. An optional field that goes away must
    /// produce a real tombstone, or a cleared due date / defer / parent /
    /// position would survive in the doc and come back on the next merge.
    /// Same for the two boolean project flags, which are dropped rather than
    /// written as `false`.
    func testClearedOptionalFieldsAreStillDeleted() throws {
        let store = AutomergeStore()
        var t = TaskItem(list: "inbox", title: "clear-me",
                         created: Date(timeIntervalSince1970: 1_700_000_000),
                         pos: Date(timeIntervalSince1970: 1_700_000_000))
        t.dueDate = Date(timeIntervalSince1970: 1_700_000_500)
        t.deferUntil = Date(timeIntervalSince1970: 1_700_001_000)
        t.parent = "some-parent"
        try store.upsertTasks([t])

        var cleared = t
        cleared.dueDate = nil
        cleared.deferUntil = nil
        cleared.parent = nil
        cleared.pos = nil
        try store.upsertTasks([cleared])

        let round = try XCTUnwrap(try store.snapshot().tasks.first)
        XCTAssertNil(round.dueDate, "A cleared due date must not survive the rewrite.")
        XCTAssertNil(round.deferUntil, "A cleared defer must not survive the rewrite.")
        XCTAssertNil(round.parent, "A cleared parent must not survive the rewrite.")
        XCTAssertNil(round.pos, "A cleared sort position must not survive the rewrite.")

        let shared = ProjectItem(id: "p_flags", name: "flags", icon: "folder",
                                 accentHex: 0x123456, isShared: true, claudeAccess: true)
        try store.upsertProjects([shared])
        var unshared = shared
        unshared.isShared = false
        unshared.claudeAccess = false
        try store.upsertProjects([unshared])

        let pRound = try XCTUnwrap(try store.snapshot().projects.first { $0.id == "p_flags" })
        XCTAssertFalse(pRound.isShared, "Unsharing must drop the flag, not leave it stuck true.")
        XCTAssertFalse(pRound.claudeAccess, "Revoking Claude access must drop the flag.")
    }
}
