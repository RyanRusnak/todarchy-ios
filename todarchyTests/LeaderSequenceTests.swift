#if os(macOS)
import XCTest

@MainActor
final class LeaderSequenceTests: XCTestCase {

    // MARK: - dd / fd / fs

    func testDDefersAndIsNotALeader() {
        var r = MainKeyRouter()
        // `d` used to be the delete leader (`dd`); it's now the defer key and
        // fires immediately on the first press (delete moved to the ⌫ key).
        XCTAssertEqual(r.route(chars: "d", keyCode: 0), .deferSelected)
    }

    func testFdTogglesShowDone() {
        var r = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(r.route(chars: "f", keyCode: 0, now: now), .pass)
        XCTAssertEqual(r.route(chars: "d", keyCode: 0, now: now.addingTimeInterval(0.1)), .toggleShowDone)
    }

    func testFsTogglesShowDeferred() {
        var r = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(r.route(chars: "f", keyCode: 0, now: now), .pass)
        XCTAssertEqual(r.route(chars: "s", keyCode: 0, now: now.addingTimeInterval(0.1)), .toggleShowDeferred)
    }

    // MARK: - gi / g1..g5

    func testGiGoesToInbox() {
        var r = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(r.route(chars: "g", keyCode: 0, now: now), .pass)
        XCTAssertEqual(r.route(chars: "i", keyCode: 0, now: now.addingTimeInterval(0.1)), .gotoList(0))
    }

    func testG3GoesToThirdProject() {
        var r = MainKeyRouter()
        let now = Date()
        _ = r.route(chars: "g", keyCode: 0, now: now)
        XCTAssertEqual(r.route(chars: "3", keyCode: 0, now: now.addingTimeInterval(0.1)), .gotoList(3))
    }

    func testGnOpensProjectEditor() {
        var r = MainKeyRouter()
        let now = Date()
        _ = r.route(chars: "g", keyCode: 0, now: now)
        XCTAssertEqual(r.route(chars: "n", keyCode: 0, now: now.addingTimeInterval(0.1)), .openProjectEditor)
    }

    // MARK: - mi / m1..m5

    func testMiMovesToInbox() {
        var r = MainKeyRouter()
        let now = Date()
        XCTAssertEqual(r.route(chars: "m", keyCode: 0, now: now), .pass)
        XCTAssertEqual(r.route(chars: "i", keyCode: 0, now: now.addingTimeInterval(0.1)), .moveSelectedToList(0))
    }

    func testM2MovesToSecondProject() {
        var r = MainKeyRouter()
        let now = Date()
        _ = r.route(chars: "m", keyCode: 0, now: now)
        XCTAssertEqual(r.route(chars: "2", keyCode: 0, now: now.addingTimeInterval(0.1)), .moveSelectedToList(2))
    }

    // MARK: - Plain digits

    func testDigit0GoesToInbox() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "0", keyCode: 0), .gotoList(0))
    }

    func testDigit1GoesToFirstProject() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "1", keyCode: 0), .gotoList(1))
    }

    // MARK: - Unknown-sequence fallthrough

    func testUnknownSequenceFallsThroughToSingleKey() {
        var r = MainKeyRouter()
        let now = Date()
        // `g` sets pending.
        _ = r.route(chars: "g", keyCode: 0, now: now)
        // `j` doesn't match `gj`, so pending is cleared and `j` is applied.
        XCTAssertEqual(r.route(chars: "j", keyCode: 0, now: now.addingTimeInterval(0.1)), .selectNext)
    }

    func testLeaderTimesOut() {
        var r = MainKeyRouter()
        let now = Date()
        _ = r.route(chars: "g", keyCode: 0, now: now)
        // 1.0s later, pending has expired. A lone `g` is just a new leader — .pass.
        XCTAssertEqual(r.route(chars: "g", keyCode: 0, now: now.addingTimeInterval(1.0)), .pass)
    }

    // MARK: - Aliases

    func testAAliasesToOpenCapture() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "a", keyCode: 0), .openCapture)
    }

    func testQuestionMarkAliasesToOpenPalette() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "?", keyCode: 0, modifiers: .shift), .openPalette)
    }

    // MARK: - Escape

    func testEscapeReturnsClearFilters() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "", keyCode: MacKeyCode.escape), .clearFilters)
    }

    // MARK: - `e`

    func testEEditsSelected() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "e", keyCode: 0), .editSelected)
    }

    // MARK: - Store integration

    func testGotoListMovesActiveSelection() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("inbox")
        XCTAssertTrue(store.gotoList(at: 2))
        if case .list(let id) = store.activeSelection {
            XCTAssertEqual(id, store.allLists[2].id)
        } else {
            XCTFail("Expected list selection")
        }
    }

    func testGotoListOutOfRangeIsNoOp() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("inbox")
        XCTAssertFalse(store.gotoList(at: 99))
    }

    func testMoveSelectedToListRelocatesTask() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let id = store.selectedTaskId!
        let targetIndex = 2   // some project
        let targetId = store.allLists[targetIndex].id
        XCTAssertTrue(store.moveSelectedToList(at: targetIndex))
        XCTAssertEqual(store.tasks.first(where: { $0.id == id })!.list, targetId)
    }

    func testMoveSelectedToListWithoutSelectionIsNoOp() {
        let store = TaskStore.ephemeral()
        store.selectedTaskId = nil
        XCTAssertFalse(store.moveSelectedToList(at: 0))
    }

    func testClearContextFilterNoops() {
        let store = TaskStore.ephemeral()
        store.activeContextFilter = nil
        XCTAssertFalse(store.clearContextFilter())
    }

    func testClearContextFilterClears() {
        let store = TaskStore.ephemeral()
        store.activeContextFilter = .work
        XCTAssertTrue(store.clearContextFilter())
        XCTAssertNil(store.activeContextFilter)
    }

    // MARK: - Monitor apply

    func testMonitorApplyToggleShowDone() {
        let store = TaskStore.ephemeral()
        XCTAssertFalse(store.showDone)
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.toggleShowDone))
        XCTAssertTrue(store.showDone)
        XCTAssertTrue(m.apply(.toggleShowDone))
        XCTAssertFalse(store.showDone)
    }

    func testMonitorApplyToggleShowDeferred() {
        let store = TaskStore.ephemeral()
        XCTAssertFalse(store.showDeferred)
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.toggleShowDeferred))
        XCTAssertTrue(store.showDeferred)
    }

    func testMonitorApplyGotoList() {
        let store = TaskStore.ephemeral()
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.gotoList(1)))
        if case .list(let id) = store.activeSelection {
            XCTAssertEqual(id, store.allLists[1].id)
        } else {
            XCTFail("Expected list selection")
        }
    }

    func testMonitorApplyMoveSelectedToList() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let id = store.selectedTaskId!
        let m = MacMainKeyMonitor()
        m.store = store
        let target = 2
        XCTAssertTrue(m.apply(.moveSelectedToList(target)))
        XCTAssertEqual(store.tasks.first(where: { $0.id == id })!.list, store.allLists[target].id)
    }

    func testMonitorApplyEditSelected() {
        let store = TaskStore.ephemeral()
        store.activeSelection = .list("p_work")
        store.selectFirst()
        let id = store.selectedTaskId
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.editSelected))
        XCTAssertEqual(store.editingTaskId, id)
    }

    func testMonitorApplyEditSelectedNoopsWithoutSelection() {
        let store = TaskStore.ephemeral()
        store.selectedTaskId = nil
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertFalse(m.apply(.editSelected))
        XCTAssertNil(store.editingTaskId)
    }

    func testMonitorApplyClearFiltersClearsContextFilter() {
        let store = TaskStore.ephemeral()
        store.activeContextFilter = .work
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.clearFilters))
        XCTAssertNil(store.activeContextFilter)
    }

    func testMonitorApplyClearFiltersNoFilterReturnsFalse() {
        let store = TaskStore.ephemeral()
        store.activeContextFilter = nil
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertFalse(m.apply(.clearFilters))
    }

    func testMonitorApplyOpenProjectEditorPostsNotification() {
        let m = MacMainKeyMonitor()
        let exp = expectation(forNotification: .todarchyOpenProjectEditor, object: nil)
        _ = m.apply(.openProjectEditor)
        wait(for: [exp], timeout: 1.0)
    }

    func testUpdateProjectAccent() {
        let store = TaskStore.ephemeral()
        let p = store.projects.first!
        store.updateProjectAccent(id: p.id, hex: 0xABCDEF)
        XCTAssertEqual(store.projects.first(where: { $0.id == p.id })!.accentHex, 0xABCDEF)
    }
}
#endif
