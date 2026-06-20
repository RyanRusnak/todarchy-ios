#if os(macOS)
import XCTest

@MainActor
final class MacKeyRouterTests: XCTestCase {

    // MARK: - Arrow keys

    func testDownArrowRoutesToSelectNext() {
        var router = MainKeyRouter()
        let intent = router.route(chars: "", keyCode: MacKeyCode.downArrow)
        XCTAssertEqual(intent, .selectNext)
    }

    func testUpArrowRoutesToSelectPrevious() {
        var router = MainKeyRouter()
        let intent = router.route(chars: "", keyCode: MacKeyCode.upArrow)
        XCTAssertEqual(intent, .selectPrevious)
    }

    // MARK: - Vim keys

    func testJMovesDown() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "j", keyCode: 0), .selectNext)
    }

    func testKMovesUp() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "k", keyCode: 0), .selectPrevious)
    }

    func testXTogglesComplete() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "x", keyCode: 0), .toggleComplete)
    }

    func testOOpensCapture() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "o", keyCode: 0), .openCapture)
    }

    func testCapitalOOpensCapture() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "O", keyCode: 0, modifiers: .shift), .openCapture)
    }

    func testDDefers() {
        var router = MainKeyRouter()
        // `d` defers immediately (not a leader anymore — no `dd` delete).
        XCTAssertEqual(router.route(chars: "d", keyCode: 0), .deferSelected)
    }

    func testSOpensSendTo() {
        var router = MainKeyRouter()
        // `s` no longer defers — it opens the send-to project picker.
        XCTAssertEqual(router.route(chars: "s", keyCode: 0), .openSendTo)
    }

    func testMonitorApplyOpenSendToPostsNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenSendTo, object: nil)
        _ = monitor.apply(.openSendTo)
        wait(for: [exp], timeout: 1.0)
    }

    func testFDStillTogglesShowDone() {
        // `d` following the `f` leader must still resolve to `fd` — the
        // pending-leader pass runs before the single-key `d` defer binding.
        var router = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(router.route(chars: "f", keyCode: 0, now: now), .pass)
        XCTAssertEqual(
            router.route(chars: "d", keyCode: 0, now: now.addingTimeInterval(0.1)),
            .toggleShowDone
        )
    }

    func testSpaceTogglesComplete() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: " ", keyCode: 0), .toggleComplete)
    }

    func testUUndos() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "u", keyCode: 0), .undo)
    }

    // MARK: - Shift reorder

    func testShiftJReordersDown() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "J", keyCode: 0, modifiers: .shift),
            .moveSelectedDown
        )
    }

    func testShiftKReordersUp() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "K", keyCode: 0, modifiers: .shift),
            .moveSelectedUp
        )
    }

    func testShiftDownArrowReordersDown() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "", keyCode: MacKeyCode.downArrow, modifiers: .shift),
            .moveSelectedDown
        )
    }

    func testShiftUpArrowReordersUp() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "", keyCode: MacKeyCode.upArrow, modifiers: .shift),
            .moveSelectedUp
        )
    }

    func testPlainDownArrowStillSelectsNext() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "", keyCode: MacKeyCode.downArrow, modifiers: []),
            .selectNext
        )
    }

    func testMonitorApplyMoveSelectedDown() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let firstId = store.selectedTaskId
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        _ = monitor.apply(.moveSelectedDown)
        // Selection stays on the same task; the task moved down in the view.
        XCTAssertEqual(store.selectedTaskId, firstId)
    }

    // MARK: - List cycling (left/right arrows)

    func testRightArrowCyclesNextList() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "", keyCode: MacKeyCode.rightArrow),
            .selectNextList
        )
    }

    func testLeftArrowCyclesPreviousList() {
        var router = MainKeyRouter()
        XCTAssertEqual(
            router.route(chars: "", keyCode: MacKeyCode.leftArrow),
            .selectPreviousList
        )
    }

    func testMonitorApplySelectNextList() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("inbox")
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.selectNextList))
        if case .list(let id) = store.activeSelection {
            XCTAssertNotEqual(id, "inbox")
        } else {
            XCTFail("Expected list selection")
        }
    }

    // MARK: - Inspector

    func testIKeyTogglesInspector() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "i", keyCode: 0), .toggleInspector)
    }

    func testMonitorApplyToggleInspectorPostsNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyToggleInspector, object: nil)
        _ = monitor.apply(.toggleInspector)
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Search (/) and Palette (:)

    func testSlashOpensSearch() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "/", keyCode: 0), .openSearch)
    }

    func testColonOpensPalette() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: ":", keyCode: 0), .openPalette)
    }

    func testMonitorApplyOpenSearchPostsNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenSearch, object: nil)
        _ = monitor.apply(.openSearch)
        wait(for: [exp], timeout: 1.0)
    }

    func testMonitorApplyOpenPalettePostsNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenPalette, object: nil)
        _ = monitor.apply(.openPalette)
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Round out monitor apply coverage

    func testMonitorApplySelectPrevious() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectLast()
        let last = store.selectedTaskId
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.selectPrevious))
        XCTAssertNotEqual(store.selectedTaskId, last)
    }

    func testMonitorApplySelectFirstAndLast() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.selectLast))
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.last?.id)
        XCTAssertTrue(monitor.apply(.selectFirst))
        XCTAssertEqual(store.selectedTaskId, store.viewTasks.first?.id)
    }

    func testMonitorApplyMoveSelectedUp() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_wedding")
        store.selectFirst()
        _ = store.moveSelectedDown()
        let afterMove = store.selectedTaskId
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.moveSelectedUp))
        XCTAssertEqual(store.selectedTaskId, afterMove, "Selection follows the moved task")
    }

    func testMonitorApplyDeferSelectedPostsPickerNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenDeferPicker, object: nil)
        _ = monitor.apply(.deferSelected)
        wait(for: [exp], timeout: 1.0)
    }

    func testMonitorApplySelectPreviousList() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list(store.allLists.first!.id)
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.selectPreviousList))
        // Should wrap to the last list.
        if case .list(let id) = store.activeSelection {
            XCTAssertEqual(id, store.allLists.last!.id)
        } else {
            XCTFail("Expected list selection")
        }
    }

    func testCapitalGJumpsToLast() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "G", keyCode: 0, modifiers: .shift), .selectLast)
    }

    // MARK: - Return + Delete

    func testReturnOpensCapture() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "\r", keyCode: MacKeyCode.returnKey), .openCapture)
    }

    func testNumpadEnterOpensCapture() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "\r", keyCode: MacKeyCode.numpadEnter), .openCapture)
    }

    func testDeleteKeyDeletes() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "", keyCode: MacKeyCode.delete), .deleteSelected)
    }

    // MARK: - gg sequence

    func testSingleGPassesThrough() {
        var router = MainKeyRouter()
        let first = router.route(chars: "g", keyCode: 0)
        XCTAssertEqual(first, .pass)
    }

    func testDoubleGJumpsToFirst() {
        var router = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(router.route(chars: "g", keyCode: 0, now: now), .pass)
        XCTAssertEqual(
            router.route(chars: "g", keyCode: 0, now: now.addingTimeInterval(0.3)),
            .selectFirst
        )
    }

    func testGFollowedByOtherKeyClearsPending() {
        var router = MainKeyRouter()
        let now = Date()
        _ = router.route(chars: "g", keyCode: 0, now: now)
        _ = router.route(chars: "j", keyCode: 0, now: now.addingTimeInterval(0.1))
        // Now a single g should NOT trigger selectFirst (lastG was cleared by j).
        XCTAssertEqual(router.route(chars: "g", keyCode: 0, now: now.addingTimeInterval(0.2)), .pass)
    }

    func testGGOutsideWindowDoesNotJump() {
        var router = MainKeyRouter()
        let now = Date()
        _ = router.route(chars: "g", keyCode: 0, now: now)
        // Second g arrives beyond ggWindow.
        XCTAssertEqual(
            router.route(chars: "g", keyCode: 0, now: now.addingTimeInterval(1.0)),
            .pass
        )
    }

    // MARK: - Modifier pass-through

    func testCommandModifiedKeysPassThrough() {
        var router = MainKeyRouter()
        // ⌘N should not be handled by the router — it's a menu shortcut.
        XCTAssertEqual(router.route(chars: "n", keyCode: 0, modifiers: .command), .pass)
        // ⌘K either.
        XCTAssertEqual(router.route(chars: "k", keyCode: 0, modifiers: .command), .pass)
    }

    func testControlModifiedKeysPassThrough() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "j", keyCode: 0, modifiers: .control), .pass)
    }

    func testUnknownKeysPassThrough() {
        var router = MainKeyRouter()
        XCTAssertEqual(router.route(chars: "q", keyCode: 0), .pass)
        XCTAssertEqual(router.route(chars: "!", keyCode: 0), .pass)
    }

    // MARK: - Palette routing

    func testPaletteUpArrow() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "", keyCode: MacKeyCode.upArrow),
            .moveUp
        )
    }

    func testPaletteDownArrow() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "", keyCode: MacKeyCode.downArrow),
            .moveDown
        )
    }

    func testPaletteReturnCommits() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "\r", keyCode: MacKeyCode.returnKey),
            .commit
        )
    }

    func testPaletteEscapeCancels() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "", keyCode: MacKeyCode.escape),
            .cancel
        )
    }

    func testPaletteCtrlNMovesDown() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "n", keyCode: 0, modifiers: .control),
            .moveDown
        )
    }

    func testPaletteCtrlPMovesUp() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "p", keyCode: 0, modifiers: .control),
            .moveUp
        )
    }

    func testPaletteLetterKeysPassThrough() {
        XCTAssertEqual(
            PaletteKeyRouter.route(chars: "a", keyCode: 0),
            .pass
        )
    }

    // MARK: - KeyEventMonitor apply

    func testMonitorApplySelectNext() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let first = store.selectedTaskId
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.selectNext))
        XCTAssertNotNil(store.selectedTaskId)
        XCTAssertNotEqual(store.selectedTaskId, first)
    }

    func testMonitorApplyToggleCompleteTogglesSelected() {
        // .toggleComplete mutates the store by selection id directly. A
        // single keypress must flip exactly the selected task's done-state.
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let selected = store.selectedTaskId!
        XCTAssertFalse(store.tasks.first(where: { $0.id == selected })!.isDone)
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.toggleComplete))
        XCTAssertTrue(store.tasks.first(where: { $0.id == selected })!.isDone)
    }

    func testMonitorApplyToggleCompleteLeavesOtherTasksUntouched() {
        // Regression guard for the phantom-completion bug: toggling the
        // selected task must NOT change the done-state of any other task.
        // The old broadcast (`.todarchyToggleDone`) was observed by every
        // mounted TaskRow and acted on stale `isSelected` captures, so one
        // keypress completed (or un-completed) unrelated tasks across
        // projects. Routing through the store by selection id makes that
        // structurally impossible.
        let store = TaskStore.ephemeral()
        // Pre-complete one task in another project so we can detect a
        // spurious un-complete as well as a spurious complete.
        let weddingFirst = store.tasks.first(where: { $0.list == "p_wedding" })!.id
        store.toggleDone(weddingFirst)

        store.activeSelection = .list("p_work")
        store.selectFirst()
        let selected = store.selectedTaskId!

        let othersBefore: [String: Bool] = Dictionary(
            uniqueKeysWithValues: store.tasks
                .filter { $0.id != selected }
                .map { ($0.id, $0.isDone) }
        )

        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.toggleComplete))

        XCTAssertTrue(store.tasks.first(where: { $0.id == selected })!.isDone)
        for (id, wasDone) in othersBefore {
            XCTAssertEqual(
                store.tasks.first(where: { $0.id == id })!.isDone,
                wasDone,
                "Task \(id) changed done-state when a different task was toggled"
            )
        }
    }

    func testMonitorApplyToggleCompleteWithNoSelectionChangesNothing() {
        let store = TaskStore.ephemeral()
        store.selectedTaskId = nil
        let before: [String: Bool] = Dictionary(
            uniqueKeysWithValues: store.tasks.map { ($0.id, $0.isDone) }
        )
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        _ = monitor.apply(.toggleComplete)
        for (id, wasDone) in before {
            XCTAssertEqual(store.tasks.first(where: { $0.id == id })!.isDone, wasDone)
        }
    }

    func testMonitorApplyDelete() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let id = store.selectedTaskId!
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        XCTAssertTrue(monitor.apply(.deleteSelected))
        XCTAssertFalse(store.tasks.contains(where: { $0.id == id }))
    }

    func testMonitorApplyPassReturnsFalse() {
        let monitor = MacMainKeyMonitor()
        XCTAssertFalse(monitor.apply(.pass))
    }

    func testMonitorApplyUndoRestoresState() {
        // Drive the toggle directly to keep this assertion focused on the
        // undo system rather than the keyboard-routing plumbing.
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let id = store.selectedTaskId!
        let monitor = MacMainKeyMonitor()
        monitor.store = store
        _ = store.toggleSelectedDone()
        XCTAssertTrue(store.tasks.first(where: { $0.id == id })!.isDone)
        XCTAssertTrue(monitor.apply(.undo))
        XCTAssertFalse(store.tasks.first(where: { $0.id == id })!.isDone)
    }

    func testMonitorApplyOpenCapturePostsNotification() {
        let monitor = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenCapture, object: nil)
        _ = monitor.apply(.openCapture)
        wait(for: [exp], timeout: 1.0)
    }
}
#endif
