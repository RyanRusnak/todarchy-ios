import XCTest
@testable import todarchy

/// Covers the behaviors the macOS MenuBarExtraView relies on: routing
/// quick-add captures to the inbox regardless of the main window's
/// `activeSelection`, and toggling completion on rows shown in the popover.
@MainActor
final class MenuBarQuickAddTests: XCTestCase {
    var store: TaskStore!

    override func setUp() async throws {
        store = TaskStore(persistence: nil)
        store.tasks = []
        store.projects = [
            ProjectItem(id: "p_work", name: "work", icon: "briefcase", accent: .blue)
        ]
    }

    // MARK: - Add: always lands in inbox

    func testQuickAddRoutesToInboxEvenWhenActiveSelectionIsAProject() {
        store.activeSelection = .list("p_work")

        let id = store.add(raw: "buy milk", list: "inbox")

        XCTAssertNotNil(id)
        let added = store.tasks.first { $0.id == id }
        XCTAssertEqual(added?.list, "inbox",
                       "Menu-bar add must land in inbox, not in the active project.")
        XCTAssertEqual(added?.title, "buy milk")
    }

    func testQuickAddIgnoresEmptyAndWhitespaceInput() {
        XCTAssertNil(store.add(raw: "", list: "inbox"))
        XCTAssertNil(store.add(raw: "   ", list: "inbox"))
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testQuickAddParsesContextAndDueTokens() {
        let id = store.add(raw: "ship release !today @work", list: "inbox")
        let task = store.tasks.first { $0.id == id }
        XCTAssertEqual(task?.title, "ship release")
        XCTAssertEqual(task?.due, .today)
        XCTAssertEqual(task?.ctx, .work)
        XCTAssertEqual(task?.list, "inbox")
    }

    // MARK: - Edit: toggle done from the popover row

    func testToggleDoneFromPopoverFlipsState() {
        let id = store.add(raw: "reply to matteo", list: "inbox")!
        XCTAssertFalse(store.tasks.first { $0.id == id }!.isDone)

        store.toggleDone(id)
        XCTAssertTrue(store.tasks.first { $0.id == id }!.isDone)

        store.toggleDone(id)
        XCTAssertFalse(store.tasks.first { $0.id == id }!.isDone)
    }

    func testTodayFilterMatchesMenuBarPopover() {
        // Mirrors MenuBarExtraView.todayTasks: open + not deferred + due today.
        _ = store.add(raw: "background inbox item", list: "inbox")
        let dueTodayId = store.add(raw: "due today now !today", list: "inbox")!
        let doneId = store.add(raw: "already done !today", list: "inbox")!
        store.toggleDone(doneId)

        let visible = store.tasks.filter { !$0.isDone && !$0.isDeferred && $0.due == .today }
        XCTAssertEqual(visible.map(\.id), [dueTodayId])
    }

    // MARK: - Popover sectioning: today + inbox

    func testInboxSectionShowsCapturedTasksThatArentDueToday() {
        // Mirrors MenuBarExtraView.inboxTasks: list == inbox, open, not
        // deferred, and not already in the today section.
        let captureId = store.add(raw: "buy milk", list: "inbox")!
        let scheduledId = store.add(raw: "ship release !today", list: "inbox")!
        let projectId = store.add(raw: "work thing", list: "p_work")!

        let inboxOnly = store.tasks.filter {
            $0.list == "inbox" && !$0.isDone && !$0.isDeferred && $0.due != .today
        }
        XCTAssertEqual(inboxOnly.map(\.id), [captureId],
                       "Inbox section should show fresh captures and exclude both today-scheduled inbox items and project tasks.")
        XCTAssertFalse(inboxOnly.contains { $0.id == scheduledId })
        XCTAssertFalse(inboxOnly.contains { $0.id == projectId })
    }

    func testInboxSectionHidesCompletedAndDeferredCaptures() {
        let openId = store.add(raw: "open capture", list: "inbox")!
        let doneId = store.add(raw: "done capture", list: "inbox")!
        let deferredId = store.add(raw: "later", list: "inbox")!
        store.toggleDone(doneId)
        store.defer_(deferredId, until: Date().addingTimeInterval(3600 * 24))

        let visible = store.tasks.filter {
            $0.list == "inbox" && !$0.isDone && !$0.isDeferred && $0.due != .today
        }
        XCTAssertEqual(visible.map(\.id), [openId])
    }

    func testFreshCaptureIsImmediatelyVisibleInPopover() {
        // The whole point of the inbox section: capture via the menu bar,
        // see it in the same popover without needing the !today flag.
        store.activeSelection = .list("p_work")
        let id = store.add(raw: "remember this", list: "inbox")!

        let popoverIds = (
            store.tasks.filter { !$0.isDone && !$0.isDeferred && $0.due == .today }
            + store.tasks.filter {
                $0.list == "inbox" && !$0.isDone && !$0.isDeferred && $0.due != .today
            }
        ).map(\.id)
        XCTAssertTrue(popoverIds.contains(id))
    }

    // MARK: - Edit: title + completion mutations from the row

    func testSetTitleEditsTaskShownInPopover() {
        let id = store.add(raw: "draft", list: "inbox")!
        store.setTitle(id, title: "draft v2")
        XCTAssertEqual(store.tasks.first { $0.id == id }?.title, "draft v2")
    }
}
