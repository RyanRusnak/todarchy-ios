import XCTest

@MainActor
final class NestingTests: XCTestCase {
    var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore.ephemeral()
        store.tasks = TaskStore.demoTasks()
        // Work with the inbox so we have a predictable short list.
        store.activeSelection = .list("inbox")
    }

    // MARK: - Router

    func testTabIndentsSelected() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "\t", keyCode: MacKeyCode.tab), .indentSelected)
    }

    func testShiftTabOutdentsSelected() {
        var r = MainKeyRouter()
        XCTAssertEqual(
            r.route(chars: "\t", keyCode: MacKeyCode.tab, modifiers: .shift),
            .outdentSelected
        )
    }

    func testZTogglesCollapse() {
        var r = MainKeyRouter()
        XCTAssertEqual(r.route(chars: "z", keyCode: 0), .toggleCollapseSelected)
    }

    // MARK: - Indent / Outdent

    func testIndentMakesTaskAChildOfPrecedingSibling() {
        // Seed inbox is [pick up pasta, reply to matteo, figure out btrfs]
        // in that order. Select the second one and indent it.
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        store.selectedTaskId = second
        XCTAssertTrue(store.indentSelected())
        XCTAssertEqual(store.tasks.first(where: { $0.id == second })!.parent, first)
    }

    func testIndentFailsAtTopOfList() {
        store.selectFirst()
        XCTAssertFalse(store.indentSelected())
    }

    func testOutdentMakesTaskASiblingOfParent() {
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        store.selectedTaskId = second
        _ = store.indentSelected()  // now a child of `first`
        XCTAssertEqual(store.tasks.first(where: { $0.id == second })!.parent, first)

        XCTAssertTrue(store.outdentSelected())
        XCTAssertNil(store.tasks.first(where: { $0.id == second })!.parent)
    }

    func testOutdentOnRootTaskIsNoOp() {
        store.selectFirst()
        XCTAssertFalse(store.outdentSelected())
    }

    // MARK: - viewTree

    func testViewTreeReflectsNesting() {
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        store.selectedTaskId = second
        _ = store.indentSelected()

        let tree = store.viewTree
        guard let parentRow = tree.first(where: { $0.id == first }),
              let childRow = tree.first(where: { $0.id == second }) else {
            XCTFail("Rows missing")
            return
        }
        XCTAssertEqual(parentRow.depth, 0)
        XCTAssertEqual(childRow.depth, 1)
        XCTAssertTrue(parentRow.hasChildren)
        XCTAssertFalse(childRow.hasChildren)
    }

    // MARK: - Collapse

    func testToggleCollapseHidesChildrenFromTree() {
        let parent = store.viewTasks[0].id
        let child = store.viewTasks[1].id
        store.selectedTaskId = child
        _ = store.indentSelected()

        // Child is visible.
        XCTAssertTrue(store.viewTree.contains(where: { $0.id == child }))

        // Collapse parent.
        store.selectedTaskId = parent
        XCTAssertTrue(store.toggleCollapseSelected())

        XCTAssertTrue(store.viewTree.contains(where: { $0.id == parent }))
        XCTAssertFalse(store.viewTree.contains(where: { $0.id == child }),
                       "Child row should be hidden when parent is collapsed")
    }

    func testToggleCollapseOnLeafIsNoOp() {
        store.selectFirst()
        XCTAssertFalse(store.toggleCollapseSelected())
    }

    // MARK: - Cascade delete

    func testDeleteSubtreeRemovesDescendants() {
        let parent = store.viewTasks[0].id
        let child = store.viewTasks[1].id
        store.selectedTaskId = child
        _ = store.indentSelected()

        XCTAssertTrue(store.deleteSubtree(parent))
        XCTAssertFalse(store.tasks.contains(where: { $0.id == parent }))
        XCTAssertFalse(store.tasks.contains(where: { $0.id == child }))
    }

    func testDeleteSelectedCascades() {
        let parent = store.viewTasks[0].id
        let child = store.viewTasks[1].id
        store.selectedTaskId = child
        _ = store.indentSelected()
        store.selectedTaskId = parent

        XCTAssertTrue(store.deleteSelected())
        XCTAssertFalse(store.tasks.contains(where: { $0.id == parent }))
        XCTAssertFalse(store.tasks.contains(where: { $0.id == child }))
    }

    // MARK: - Monitor apply

    func testMonitorApplyIndent() {
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        store.selectedTaskId = second
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.indentSelected))
        XCTAssertEqual(store.tasks.first(where: { $0.id == second })!.parent, first)
    }

    func testMonitorApplyOutdent() {
        let first = store.viewTasks[0].id
        let second = store.viewTasks[1].id
        store.selectedTaskId = second
        _ = store.indentSelected()
        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.outdentSelected))
        XCTAssertNil(store.tasks.first(where: { $0.id == second })!.parent)
        _ = first
    }

    func testMonitorApplyToggleCollapse() {
        let parent = store.viewTasks[0].id
        let child = store.viewTasks[1].id
        store.selectedTaskId = child
        _ = store.indentSelected()
        store.selectedTaskId = parent

        let m = MacMainKeyMonitor()
        m.store = store
        XCTAssertTrue(m.apply(.toggleCollapseSelected))
        XCTAssertTrue(store.collapsedIds.contains(parent))
    }
}
