#if os(macOS)
import XCTest

@MainActor
final class CommandPaletteModelTests: XCTestCase {

    private func cmds(_ names: String...) -> [PaletteCommand] {
        names.map { name in
            PaletteCommand(name: name, hint: nil, action: {})
        }
    }

    // MARK: - Filtering

    func testEmptyQueryReturnsAll() {
        let m = CommandPaletteModel(commands: cmds("New Task", "Go to Inbox", "Toggle Done"))
        XCTAssertEqual(m.results.count, 3)
    }

    func testCaseInsensitiveFilter() {
        let m = CommandPaletteModel(commands: cmds("New Task", "Go to Inbox"))
        m.query = "new"
        XCTAssertEqual(m.results.map(\.name), ["New Task"])
    }

    func testFilterMatchesAnywhereInName() {
        let m = CommandPaletteModel(commands: cmds("New Task", "Go to Inbox", "Toggle Inspector"))
        m.query = "inb"
        XCTAssertEqual(m.results.map(\.name), ["Go to Inbox"])
    }

    // MARK: - Navigation

    func testMoveDownWraps() {
        let m = CommandPaletteModel(commands: cmds("a", "b", "c"))
        XCTAssertEqual(m.highlighted, 0)
        m.moveDown()
        XCTAssertEqual(m.highlighted, 1)
        m.moveDown()
        XCTAssertEqual(m.highlighted, 2)
        m.moveDown()
        XCTAssertEqual(m.highlighted, 0, "Should wrap to the start")
    }

    func testMoveUpWrapsFromTop() {
        let m = CommandPaletteModel(commands: cmds("a", "b", "c"))
        m.moveUp()
        XCTAssertEqual(m.highlighted, 2, "Should wrap to the end")
    }

    func testMoveOnEmptyResultsIsSafe() {
        let m = CommandPaletteModel(commands: cmds("a"))
        m.query = "zzz"
        XCTAssertEqual(m.results.count, 0)
        m.moveDown()
        m.moveUp()
        XCTAssertEqual(m.highlighted, 0)
    }

    func testQueryChangeResetsHighlightWhenOutOfRange() {
        let m = CommandPaletteModel(commands: cmds("apple", "banana", "carrot"))
        m.moveDown(); m.moveDown()  // highlighted = 2
        m.query = "apple"            // results.count = 1
        XCTAssertEqual(m.highlighted, 0)
    }

    // MARK: - Execute

    func testExecuteRunsSelectedAction() {
        var ran: String?
        let m = CommandPaletteModel(commands: [
            PaletteCommand(name: "First", hint: nil, action: { ran = "First" }),
            PaletteCommand(name: "Second", hint: nil, action: { ran = "Second" }),
        ])
        m.moveDown()
        XCTAssertTrue(m.execute())
        XCTAssertEqual(ran, "Second")
    }

    func testExecuteOnEmptyResultsReturnsFalse() {
        let m = CommandPaletteModel(commands: cmds("a"))
        m.query = "zzz"
        XCTAssertFalse(m.execute())
    }

    // MARK: - PaletteKeyMonitor apply integration

    func testMonitorApplyMoveDown() {
        let m = CommandPaletteModel(commands: cmds("a", "b"))
        let mon = MacPaletteKeyMonitor()
        mon.model = m
        XCTAssertTrue(mon.apply(.moveDown))
        XCTAssertEqual(m.highlighted, 1)
    }

    func testMonitorApplyCommitInvokesActionAndClose() {
        var ran = false
        let m = CommandPaletteModel(commands: [
            PaletteCommand(name: "Go", hint: nil, action: { ran = true })
        ])
        let mon = MacPaletteKeyMonitor()
        mon.model = m
        var closed = false
        mon.onClose = { closed = true }
        XCTAssertTrue(mon.apply(.commit))
        XCTAssertTrue(ran)
        XCTAssertTrue(closed)
    }

    func testMonitorApplyCancelClosesWithoutExecuting() {
        var ran = false
        let m = CommandPaletteModel(commands: [
            PaletteCommand(name: "Go", hint: nil, action: { ran = true })
        ])
        let mon = MacPaletteKeyMonitor()
        mon.model = m
        var closed = false
        mon.onClose = { closed = true }
        XCTAssertTrue(mon.apply(.cancel))
        XCTAssertFalse(ran)
        XCTAssertTrue(closed)
    }
}

// MARK: - Send-to project picker

@MainActor
final class SendToPickerModelTests: XCTestCase {

    private func lists(_ names: String...) -> [ProjectItem] {
        names.map { ProjectItem(id: "p_\($0)", name: $0, icon: "folder", accentHex: 0xFFFFFFFF) }
    }

    func testEmptyQueryReturnsAllLists() {
        let m = SendToPickerModel(lists: lists("work", "home", "errands"))
        XCTAssertEqual(m.results.count, 3)
    }

    func testCaseInsensitiveFilter() {
        let m = SendToPickerModel(lists: lists("Work", "Home"))
        m.query = "wor"
        XCTAssertEqual(m.results.map(\.name), ["Work"])
    }

    func testMoveDownWrapsAndTracksHighlightedList() {
        let m = SendToPickerModel(lists: lists("a", "b"))
        XCTAssertEqual(m.highlightedList?.name, "a")
        m.moveDown()
        XCTAssertEqual(m.highlightedList?.name, "b")
        m.moveDown()
        XCTAssertEqual(m.highlightedList?.name, "a", "Should wrap to the start")
    }

    func testMoveOnEmptyResultsIsSafe() {
        let m = SendToPickerModel(lists: lists("a"))
        m.query = "zzz"
        XCTAssertEqual(m.results.count, 0)
        m.moveDown(); m.moveUp()
        XCTAssertEqual(m.highlighted, 0)
        XCTAssertNil(m.highlightedList)
    }

    func testExecuteCommitsHighlightedList() {
        var chosen: String?
        let m = SendToPickerModel(lists: lists("work", "home"))
        m.onCommit = { chosen = $0.name }
        m.moveDown()
        XCTAssertTrue(m.execute())
        XCTAssertEqual(chosen, "home")
    }

    func testExecuteOnEmptyResultsReturnsFalse() {
        let m = SendToPickerModel(lists: lists("a"))
        m.query = "zzz"
        XCTAssertFalse(m.execute())
    }

    // Reuses the shared palette key monitor via PaletteNavigable.
    func testMonitorApplyCommitMovesAndCloses() {
        var chosen: String?
        let m = SendToPickerModel(lists: lists("work", "home"))
        m.onCommit = { chosen = $0.name }
        let mon = MacPaletteKeyMonitor()
        mon.model = m
        var closed = false
        mon.onClose = { closed = true }
        XCTAssertTrue(mon.apply(.commit))
        XCTAssertEqual(chosen, "work")
        XCTAssertTrue(closed)
    }
}
#endif
