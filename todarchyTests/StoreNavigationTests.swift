import XCTest

@MainActor
final class StoreNavigationTests: XCTestCase {
    var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore.ephemeral()
        // Fresh installs now seed an empty task list; these navigation
        // tests expect a realistic multi-project dataset.
        store.tasks = TaskStore.demoTasks()
        // Default selection: work project so we have a predictable > 1 row list.
        store.activeSelection = .list("p_work")
        store.showDone = false
        store.showDeferred = false
    }

    // MARK: - selectNext / selectPrevious

    func testSelectNextSelectsFirstWhenNothingSelected() {
        XCTAssertNil(store.selectedTaskId)
        store.selectNext()
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.first?.id)
    }

    func testSelectNextMovesDown() {
        store.selectFirst()
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        XCTAssertEqual(store.selectedTaskId, first)
        store.selectNext()
        XCTAssertEqual(store.selectedTaskId, second)
    }

    func testSelectNextClampsAtLastRow() {
        store.selectLast()
        let lastId = store.viewTasks.last?.id
        store.selectNext()
        XCTAssertEqual(store.selectedTaskId, lastId)
    }

    func testSelectPreviousMovesUp() {
        store.selectLast()
        let penultimate = store.viewTasks[store.viewTasks.count - 2].id
        store.selectPrevious()
        XCTAssertEqual(store.selectedTaskId, penultimate)
    }

    func testSelectPreviousClampsAtFirstRow() {
        store.selectFirst()
        let firstId = store.viewTasks.first?.id
        store.selectPrevious()
        XCTAssertEqual(store.selectedTaskId, firstId)
    }

    func testSelectFirstOnEmptyListClearsSelection() {
        // Make the list empty by filtering to a context with zero rows.
        // @read has seed tasks in the wedding list — try a filter combination that zeroes out.
        store.activeSelection = .list("inbox")
        store.activeContextFilter = .mac
        // Inbox @mac exists; pick a different combination that's empty:
        store.activeContextFilter = nil
        store.activeSelection = .list("p_empty_nonexistent")
        store.selectFirst()
        XCTAssertNil(store.selectedTaskId)
    }

    // MARK: - selectFirst / selectLast

    func testSelectFirstAndLast() {
        store.selectFirst()
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.first?.id)
        store.selectLast()
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.last?.id)
    }

    // MARK: - toggleSelectedDone

    func testToggleSelectedDoneWithoutSelectionIsNoOp() {
        XCTAssertFalse(store.toggleSelectedDone())
    }

    func testToggleSelectedDoneMarksAndUnmarks() {
        store.selectFirst()
        let id = store.selectedTaskId!
        XCTAssertTrue(store.toggleSelectedDone())
        // After toggle, the task is done. With showDone=false it falls out of viewTasks but still exists.
        let task = store.tasks.first(where: { $0.id == id })!
        XCTAssertTrue(task.isDone)
        XCTAssertTrue(store.toggleSelectedDone())
        let task2 = store.tasks.first(where: { $0.id == id })!
        XCTAssertFalse(task2.isDone)
    }

    // MARK: - deleteSelected

    func testDeleteSelectedMovesSelectionToNeighbor() {
        store.selectFirst()
        let firstId = store.selectedTaskId!
        let nextId = store.viewTasks[1].id
        XCTAssertTrue(store.deleteSelected())
        XCTAssertFalse(store.tasks.contains(where: { $0.id == firstId }))
        // After deletion, selection should be the task that was at index 1 (now index 0).
        XCTAssertEqual(store.selectedTaskId, nextId)
    }

    func testDeleteSelectedOnEmptyIsNoOp() {
        XCTAssertFalse(store.deleteSelected())
    }

    func testDeleteLastSelectsNewLast() {
        store.selectLast()
        let last = store.selectedTaskId!
        // The second-to-last row becomes the new last.
        let expectedNewSelection = store.viewTasks[store.viewTasks.count - 2].id
        XCTAssertTrue(store.deleteSelected())
        XCTAssertFalse(store.tasks.contains(where: { $0.id == last }))
        XCTAssertEqual(store.selectedTaskId, expectedNewSelection)
    }

    // MARK: - deferSelected

    func testDeferSelectedSetsFutureTimestamp() {
        store.selectFirst()
        let id = store.selectedTaskId!
        XCTAssertTrue(store.deferSelected(by: 3600))
        let t = store.tasks.first(where: { $0.id == id })!
        XCTAssertNotNil(t.deferUntil)
        XCTAssertGreaterThan(t.deferUntil!, Date())
    }

    // MARK: - add

    func testAddFromQuickAddInsertsParsed() {
        store.activeSelection = .list("inbox")
        let before = store.tasks.count
        store.add(raw: "new task @work !today /extra context")
        XCTAssertEqual(store.tasks.count, before + 1)
        // New tasks append to the end of the raw array (newest at bottom).
        let t = store.tasks.last!
        XCTAssertEqual(t.title, "new task")
        XCTAssertEqual(t.ctx, .work)
        XCTAssertEqual(t.due, .today)
        XCTAssertEqual(t.note, "extra context")
        XCTAssertEqual(t.list, "inbox")
    }

    func testAddWithEmptyRawIsNoOp() {
        let before = store.tasks.count
        store.add(raw: "   ")
        XCTAssertEqual(store.tasks.count, before)
    }

    // MARK: - Undo

    func testUndoOnEmptyHistoryReturnsFalse() {
        XCTAssertFalse(store.undo())
    }

    func testUndoRevertsToggleDone() {
        store.selectFirst()
        let id = store.selectedTaskId!
        XCTAssertFalse(store.tasks.first(where: { $0.id == id })!.isDone)
        store.toggleDone(id)
        XCTAssertTrue(store.tasks.first(where: { $0.id == id })!.isDone)
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.tasks.first(where: { $0.id == id })!.isDone)
    }

    func testUndoRevertsDelete() {
        store.selectFirst()
        let id = store.selectedTaskId!
        store.delete(id)
        XCTAssertFalse(store.tasks.contains(where: { $0.id == id }))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.tasks.contains(where: { $0.id == id }))
        // Selection is also restored.
        XCTAssertEqual(store.selectedTaskId, id)
    }

    func testUndoRevertsAdd() {
        store.activeSelection = .list("inbox")
        let before = store.tasks.count
        store.add(raw: "temp @work")
        XCTAssertEqual(store.tasks.count, before + 1)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.tasks.count, before)
    }

    func testUndoRevertsDefer() {
        store.selectFirst()
        let id = store.selectedTaskId!
        XCTAssertNil(store.tasks.first(where: { $0.id == id })!.deferUntil)
        store.defer_(id, until: Date().addingTimeInterval(3600))
        XCTAssertNotNil(store.tasks.first(where: { $0.id == id })!.deferUntil)
        XCTAssertTrue(store.undo())
        XCTAssertNil(store.tasks.first(where: { $0.id == id })!.deferUntil)
    }

    func testUndoRevertsMove() {
        store.selectFirst()
        let id = store.selectedTaskId!
        let originalList = store.tasks.first(where: { $0.id == id })!.list
        store.move(id, toList: "inbox")
        XCTAssertEqual(store.tasks.first(where: { $0.id == id })!.list, "inbox")
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.tasks.first(where: { $0.id == id })!.list, originalList)
    }

    func testMultipleUndosAreSupported() {
        store.selectFirst()
        let id = store.selectedTaskId!
        store.toggleDone(id)   // done
        store.defer_(id, until: Date().addingTimeInterval(3600))  // deferred
        store.setContext(id, ctx: .read)  // context changed
        XCTAssertEqual(store.undoDepth, 3)
        XCTAssertTrue(store.undo())  // undo context
        XCTAssertNotEqual(store.tasks.first(where: { $0.id == id })!.ctx, .read)
        XCTAssertTrue(store.undo())  // undo defer
        XCTAssertNil(store.tasks.first(where: { $0.id == id })!.deferUntil)
        XCTAssertTrue(store.undo())  // undo done
        XCTAssertFalse(store.tasks.first(where: { $0.id == id })!.isDone)
        XCTAssertFalse(store.undo())  // stack empty
    }

    func testNoOpMutationsDoNotPushHistory() {
        let before = store.undoDepth
        store.add(raw: "")           // empty → no-op
        store.toggleDone(TaskItem.newID())     // unknown id → no-op
        store.delete(TaskItem.newID())         // unknown id → no-op
        XCTAssertEqual(store.undoDepth, before)
    }

    func testSetTitleToSameValueDoesNotPushHistory() {
        store.selectFirst()
        let id = store.selectedTaskId!
        let currentTitle = store.tasks.first(where: { $0.id == id })!.title
        let before = store.undoDepth
        store.setTitle(id, title: currentTitle)
        XCTAssertEqual(store.undoDepth, before)
    }

    // MARK: - Reorder (shift+j/k)

    /// Build a store with two open wedding-planning tasks sharing due=.thisWeek.
    /// Seed data has "finalize guest list" and "tasting appointment" both with
    /// due=.thisWeek in p_wedding — they're a predictable same-group pair.
    private func makeWedding() {
        store.activeSelection = .list("p_wedding")
    }

    func testMoveSelectedDownSwapsWithNextInGroup() {
        makeWedding()
        store.selectFirst()
        let firstId = store.viewTasks[0].id
        let secondId = store.viewTasks[1].id
        // Sanity: they're in the same sort group.
        XCTAssertEqual(store.viewTasks[0].due, store.viewTasks[1].due)
        XCTAssertEqual(store.viewTasks[0].isDone, store.viewTasks[1].isDone)

        XCTAssertTrue(store.moveSelectedDown())
        XCTAssertEqual(store.viewTasks[0].id, secondId)
        XCTAssertEqual(store.viewTasks[1].id, firstId)
        XCTAssertEqual(store.selectedTaskId, firstId, "Selection follows the moved task")
    }

    func testMoveSelectedUpSwapsWithPreviousInGroup() {
        makeWedding()
        store.selectFirst()
        _ = store.moveSelectedDown()  // now second row selected (firstId)
        XCTAssertEqual(store.viewTasks[1].id, store.selectedTaskId)
        let movedBack = store.moveSelectedUp()
        XCTAssertTrue(movedBack)
        XCTAssertEqual(store.viewTasks[0].id, store.selectedTaskId)
    }

    func testMoveSelectedDownAtGroupBoundaryIsNoOp() {
        makeWedding()
        // Navigate to the last task inside the first due group.
        store.selectFirst()
        // Walk down until the next visible row is in a different group.
        while true {
            guard let sel = store.selectedTaskId,
                  let vidx = store.viewTasks.firstIndex(where: { $0.id == sel }),
                  vidx + 1 < store.viewTasks.count else { break }
            let cur = store.viewTasks[vidx]
            let nxt = store.viewTasks[vidx + 1]
            if cur.due != nxt.due || cur.isDone != nxt.isDone { break }
            store.selectNext()
        }
        guard let sid = store.selectedTaskId,
              let vidx = store.viewTasks.firstIndex(where: { $0.id == sid }),
              vidx + 1 < store.viewTasks.count else {
            XCTFail("Test setup: needs a group boundary inside p_wedding")
            return
        }
        XCTAssertNotEqual(store.viewTasks[vidx].due, store.viewTasks[vidx + 1].due)
        let snapshotIds = store.viewTasks.map(\.id)
        XCTAssertFalse(store.moveSelectedDown(), "Cannot cross sort-group boundary")
        XCTAssertEqual(store.viewTasks.map(\.id), snapshotIds)
    }

    func testMoveSelectedDownAtEndOfListIsNoOp() {
        makeWedding()
        store.selectLast()
        let snapshotIds = store.viewTasks.map(\.id)
        XCTAssertFalse(store.moveSelectedDown())
        XCTAssertEqual(store.viewTasks.map(\.id), snapshotIds)
    }

    func testMoveSelectedUpAtTopIsNoOp() {
        makeWedding()
        store.selectFirst()
        let snapshotIds = store.viewTasks.map(\.id)
        XCTAssertFalse(store.moveSelectedUp())
        XCTAssertEqual(store.viewTasks.map(\.id), snapshotIds)
    }

    func testMoveSelectedWithoutSelectionIsNoOp() {
        store.selectedTaskId = nil
        XCTAssertFalse(store.moveSelectedDown())
        XCTAssertFalse(store.moveSelectedUp())
    }

    func testReorderIsUndoable() {
        makeWedding()
        store.selectFirst()
        let firstId = store.viewTasks[0].id
        let secondId = store.viewTasks[1].id
        XCTAssertTrue(store.moveSelectedDown())
        XCTAssertEqual(store.viewTasks[0].id, secondId)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.viewTasks[0].id, firstId)
        XCTAssertEqual(store.viewTasks[1].id, secondId)
    }

    // MARK: - List cycling (←/→)

    private func currentListId() -> String? {
        if case .list(let id) = store.activeSelection { return id }
        return nil
    }

    func testSelectNextListWalksForward() {
        store.activeSelection = .list("inbox")
        store.activeContextFilter = nil
        let lists = store.allLists.map(\.id)
        XCTAssertEqual(lists.first, "inbox")

        for expected in lists.dropFirst() {
            store.selectNextList()
            XCTAssertEqual(currentListId(), expected)
        }
    }

    func testSelectNextListWrapsAtEnd() {
        let lastId = store.allLists.last!.id
        store.activeSelection = .list(lastId)
        store.activeContextFilter = nil
        store.selectNextList()
        XCTAssertEqual(currentListId(), store.allLists.first!.id)
    }

    func testSelectPreviousListWrapsAtStart() {
        store.activeSelection = .list("inbox")
        store.activeContextFilter = nil
        store.selectPreviousList()
        XCTAssertEqual(currentListId(), store.allLists.last!.id)
    }

    func testListCyclingSelectsFirstTaskOfNewList() {
        store.activeSelection = .list("inbox")
        store.activeContextFilter = nil
        store.selectedTaskId = nil
        store.selectNextList()
        XCTAssertNotNil(store.selectedTaskId, "First task of new list should be selected")
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.first?.id)
    }

    func testCyclingClearsContextFilterFirst() {
        store.activeSelection = .list("inbox")
        store.activeContextFilter = .work
        let listBefore = currentListId()
        store.selectNextList()
        // First right-arrow press when a context filter is active just cancels
        // the filter. The list selection is unchanged.
        XCTAssertNil(store.activeContextFilter)
        XCTAssertEqual(currentListId(), listBefore)
        // Second press now actually cycles.
        store.selectNextList()
        XCTAssertNotEqual(currentListId(), listBefore)
    }

    func testCyclingFromContextSelectionReturnsToALlist() {
        // If activeSelection is a .context (not a .list), cycling should pick
        // the first list. (Edge case — most UI paths use .list + filter.)
        store.activeSelection = .context(.work)
        store.activeContextFilter = nil
        store.selectNextList()
        XCTAssertEqual(currentListId(), store.allLists[1].id,
                       "Starts at index 0 then advances to 1")
    }
}
