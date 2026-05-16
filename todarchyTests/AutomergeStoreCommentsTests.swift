import XCTest
import Automerge
@testable import todarchy

/// Round-trip tests for the `comments` field on `TaskItem` — append-only
/// per-task conversation list keyed by commentId in Automerge.
final class AutomergeStoreCommentsTests: XCTestCase {

    private func makeTask(id: String = "t1", comments: [Comment] = []) -> TaskItem {
        TaskItem(id: id, list: "inbox", title: "buy salmon",
                 created: Date(timeIntervalSince1970: 1_700_000_000),
                 comments: comments)
    }

    func testFreshTaskHasNoComments() throws {
        let store = AutomergeStore()
        try store.upsertTask(makeTask())
        let snap = try store.snapshot()
        XCTAssertEqual(snap.tasks.first?.comments, [])
    }

    func testUpsertWritesCommentsAndRoundTrips() throws {
        let store = AutomergeStore()
        let c1 = Comment(id: "c1", author: "Ryan", text: "buy salmon",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let c2 = Comment(id: "c2", author: "Spouse", text: "can we do chicken instead?",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        try store.upsertTask(makeTask(comments: [c1, c2]))

        let snap = try store.snapshot()
        let comments = snap.tasks.first?.comments ?? []
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0], c1)
        XCTAssertEqual(comments[1], c2)
    }

    /// Subsequent upserts append rather than replace — the existing
    /// comment's entry survives untouched.
    func testAppendingNewCommentLeavesExistingIntact() throws {
        let store = AutomergeStore()
        let c1 = Comment(id: "c1", author: "Ryan", text: "first",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        try store.upsertTask(makeTask(comments: [c1]))

        let c2 = Comment(id: "c2", author: "Ryan", text: "second",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        try store.upsertTask(makeTask(comments: [c1, c2]))

        let comments = try store.snapshot().tasks.first?.comments ?? []
        XCTAssertEqual(comments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(comments[0].text, "first")
        XCTAssertEqual(comments[1].text, "second")
    }

    /// Comments come back in chronological order regardless of insert
    /// order, since the UI relies on this for stable display.
    func testReadIsSortedByCreatedAt() throws {
        let store = AutomergeStore()
        let later = Comment(id: "c-late", author: "A", text: "later",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_300))
        let early = Comment(id: "c-early", author: "B", text: "earlier",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        try store.upsertTask(makeTask(comments: [later, early]))
        let comments = try store.snapshot().tasks.first?.comments ?? []
        XCTAssertEqual(comments.map(\.id), ["c-early", "c-late"])
    }

    /// Concurrent appends from two devices both survive merge — the
    /// load-bearing reason to key by commentId in a Map rather than
    /// position in a List.
    func testConcurrentAppendsFromTwoDevicesBothSurvive() throws {
        let a = AutomergeStore()
        try a.upsertTask(makeTask())
        let bytes = a.save()
        let b = AutomergeStore(data: bytes)

        let fromA = Comment(id: "c-a", author: "Ryan", text: "from mac",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let fromB = Comment(id: "c-b", author: "Spouse", text: "from phone",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_105))
        try a.upsertTask(makeTask(comments: [fromA]))
        try b.upsertTask(makeTask(comments: [fromB]))

        try a.merge(b)
        let comments = try a.snapshot().tasks.first?.comments ?? []
        XCTAssertEqual(comments.count, 2, "both appends should survive merge")
        XCTAssertEqual(Set(comments.map(\.id)), ["c-a", "c-b"])
    }

    /// Upsert-only semantics: rewriting the task with empty
    /// `comments` does NOT remove existing comments from the doc.
    /// This is what makes the "I have one local stale copy but the
    /// peer added a comment" case safe — we never overwrite a peer's
    /// append. Same contract tasks/projects already follow.
    func testRewritingWithEmptyCommentsPreservesExisting() throws {
        let store = AutomergeStore()
        let c1 = Comment(id: "c1", author: "Me", text: "hi",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        try store.upsertTask(makeTask(comments: [c1]))
        // Re-upsert with empty comments. Append-only → c1 stays.
        try store.upsertTask(makeTask(comments: []))
        XCTAssertEqual(try store.snapshot().tasks.first?.comments, [c1])
    }
}

/// Round-trip for the per-project `claudeAccess` flag. Same emit-when-
/// true contract as `isShared` — drops the field when false so docs
/// that never had Claude access stay byte-stable.
final class AutomergeStoreClaudeAccessTests: XCTestCase {
    private func makeProject(claudeAccess: Bool = false) -> ProjectItem {
        ProjectItem(id: "p_test", name: "test", icon: "folder",
                    accentHex: 0x7AA2F7,
                    claudeAccess: claudeAccess)
    }

    func testDefaultsToFalse() throws {
        let store = AutomergeStore()
        try store.upsertProject(makeProject())
        XCTAssertEqual(try store.snapshot().projects.first?.claudeAccess, false)
    }

    func testRoundTripsWhenTrue() throws {
        let store = AutomergeStore()
        try store.upsertProject(makeProject(claudeAccess: true))
        XCTAssertEqual(try store.snapshot().projects.first?.claudeAccess, true)
    }

    func testFlipsBackToFalse() throws {
        let store = AutomergeStore()
        try store.upsertProject(makeProject(claudeAccess: true))
        try store.upsertProject(makeProject(claudeAccess: false))
        XCTAssertEqual(try store.snapshot().projects.first?.claudeAccess, false)
    }

    func testSurvivesSaveAndReload() throws {
        let a = AutomergeStore()
        try a.upsertProject(makeProject(claudeAccess: true))
        let b = AutomergeStore(data: a.save())
        XCTAssertEqual(try b.snapshot().projects.first?.claudeAccess, true)
    }
}
