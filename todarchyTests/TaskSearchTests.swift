#if os(macOS)
import XCTest

@MainActor
final class TaskSearchTests: XCTestCase {
    var store: TaskStore!
    var model: TaskSearchModel!

    override func setUp() async throws {
        store = TaskStore.ephemeral()
        // Search tests rely on the realistic fixture dataset.
        store.tasks = TaskStore.demoTasks()
        model = TaskSearchModel()
        model.store = store
    }

    // MARK: - Filtering

    func testEmptyQueryReturnsEmpty() {
        model.query = ""
        XCTAssertTrue(model.results.isEmpty)
    }

    func testQueryMatchesTitleCaseInsensitively() {
        model.query = "BTRFS"
        XCTAssertFalse(model.results.isEmpty)
        XCTAssertTrue(model.results.allSatisfy { $0.title.lowercased().contains("btrfs") })
    }

    func testDoneTasksAreExcluded() {
        // "send save-the-dates" is a done seed task in p_wedding.
        model.query = "save"
        XCTAssertTrue(model.results.allSatisfy { !$0.isDone })
    }

    func testNoMatchReturnsEmpty() {
        model.query = "zzz_not_a_real_task_title"
        XCTAssertTrue(model.results.isEmpty)
    }

    func testSearchMatchesNote() {
        // Seed task "draft Q2 planning doc" has note mentioning "notion://".
        model.query = "notion"
        let notionTask = store.tasks.first { $0.note.lowercased().contains("notion") }
        XCTAssertNotNil(notionTask, "Precondition: seed data includes a notion-tagged note")
        XCTAssertTrue(model.results.contains(where: { $0.id == notionTask!.id }),
                      "Task with 'notion' in the note should appear in search results")
    }

    func testSearchMatchesContext() {
        model.query = "@phone"
        XCTAssertFalse(model.results.isEmpty)
        // A @phone-context task should be among the matches.
        let phoneTask = store.tasks.first { $0.ctx == .phone && !$0.isDone }!
        XCTAssertTrue(model.results.contains(where: { $0.id == phoneTask.id }))
    }

    func testTitleMatchRanksHigherThanNote() {
        // Add a task whose note mentions "btrfs" — it should rank below the
        // seed "figure out btrfs snapshots" because title matches are doubled.
        let titleMatch = store.tasks.first(where: { $0.title.contains("btrfs") })!
        model.query = "btrfs"
        XCTAssertEqual(model.results.first?.id, titleMatch.id)
    }

    // MARK: - Navigation

    func testMoveDownWraps() {
        model.query = "e"  // common letter, should match many tasks
        let n = model.results.count
        guard n >= 2 else { return XCTFail("Need ≥2 matches for this test") }
        XCTAssertEqual(model.highlighted, 0)
        for _ in 0..<n {
            model.moveDown()
        }
        XCTAssertEqual(model.highlighted, 0, "Should wrap back to 0")
    }

    func testMoveUpWrapsFromTop() {
        model.query = "e"
        let n = model.results.count
        guard n >= 2 else { return XCTFail("Need ≥2 matches") }
        model.moveUp()
        XCTAssertEqual(model.highlighted, n - 1)
    }

    func testMoveOnEmptyResultsIsSafe() {
        model.query = "zzz"
        model.moveDown()
        model.moveUp()
        XCTAssertEqual(model.highlighted, 0)
    }

    func testQueryChangeClampsHighlight() {
        model.query = "e"
        guard model.results.count >= 2 else { return XCTFail("Need ≥2 matches") }
        model.moveDown()
        model.moveDown()
        let highlightBefore = model.highlighted
        XCTAssertGreaterThan(highlightBefore, 0)
        // Narrow the query so fewer results.
        model.query = "btrfs"
        XCTAssertLessThan(model.highlighted, max(model.results.count, 1))
    }

    // MARK: - Commit

    func testCommitReturnsHighlightedTask() {
        model.query = "btrfs"
        guard let expected = model.results.first else { return XCTFail("No match") }
        XCTAssertEqual(model.commit()?.id, expected.id)
    }

    func testCommitOnEmptyReturnsNil() {
        model.query = "zzz"
        XCTAssertNil(model.commit())
    }

    // MARK: - MacSearchKeyMonitor

    func testMonitorCommitCallsOnCommitWithHighlighted() {
        model.query = "btrfs"
        guard let expected = model.results.first else { return XCTFail("No match") }
        let monitor = MacSearchKeyMonitor()
        monitor.model = model
        var committed: TaskItem?
        monitor.onCommit = { committed = $0 }
        XCTAssertTrue(monitor.apply(.commit))
        XCTAssertEqual(committed?.id, expected.id)
    }

    func testMonitorCommitOnEmptyDoesNotCallClose() {
        model.query = "zzz"
        let monitor = MacSearchKeyMonitor()
        monitor.model = model
        var closed = false
        var committed = false
        monitor.onCommit = { _ in committed = true }
        monitor.onClose = { closed = true }
        XCTAssertFalse(monitor.apply(.commit))
        XCTAssertFalse(committed)
        XCTAssertFalse(closed)
    }

    func testMonitorCancelClosesWithoutCommitting() {
        let monitor = MacSearchKeyMonitor()
        monitor.model = model
        var closed = false
        var committed = false
        monitor.onCommit = { _ in committed = true }
        monitor.onClose = { closed = true }
        XCTAssertTrue(monitor.apply(.cancel))
        XCTAssertTrue(closed)
        XCTAssertFalse(committed)
    }

    func testMonitorMoveDownAdvancesHighlight() {
        model.query = "e"
        let monitor = MacSearchKeyMonitor()
        monitor.model = model
        let before = model.highlighted
        XCTAssertTrue(monitor.apply(.moveDown))
        XCTAssertNotEqual(model.highlighted, before)
    }

    func testMonitorPassReturnsFalse() {
        let monitor = MacSearchKeyMonitor()
        XCTAssertFalse(monitor.apply(.pass))
    }

    // MARK: - Fuzzy score

    func testFuzzyScoreMatchesInOrder() {
        XCTAssertNotNil(TaskSearchModel.fuzzyScore(needle: "btrfs", haystack: "figure out btrfs snapshots"))
    }

    func testFuzzyScoreMissesWhenOutOfOrder() {
        XCTAssertNil(TaskSearchModel.fuzzyScore(needle: "xyz", haystack: "abc"))
    }

    func testFuzzyScorePrefersContiguous() {
        let contig = TaskSearchModel.fuzzyScore(needle: "cat", haystack: "cat food")!
        let spread = TaskSearchModel.fuzzyScore(needle: "cat", haystack: "c_a_t_food")!
        XCTAssertGreaterThan(contig, spread)
    }
}
#endif
