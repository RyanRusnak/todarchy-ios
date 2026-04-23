import XCTest

final class ExportImportTests: XCTestCase {

    func testJSONRoundTrip() throws {
        let tasks = [
            TaskItem(list: "inbox", title: "one", ctx: .work, note: "note one",
                     created: Date(timeIntervalSince1970: 1_700_000_000),
                     due: .today),
            TaskItem(list: "p_x", title: "two"),
        ]
        let projects = [
            ProjectItem(id: "p_x", name: "x", icon: "folder", accent: .red)
        ]
        let data = try ExportImport.exportJSON(tasks: tasks, projects: projects)
        let back = try ExportImport.importJSON(data)
        XCTAssertEqual(back.tasks.count, 2)
        XCTAssertEqual(back.tasks.first?.title, "one")
        XCTAssertEqual(back.projects.first?.name, "x")
    }

    func testMarkdownGroupsByList() {
        let tasks = [
            TaskItem(list: "inbox", title: "from inbox"),
            TaskItem(list: "p_work", title: "from work", ctx: .work, due: .today),
        ]
        let projects = [
            ProjectItem(id: "p_work", name: "work", icon: "briefcase.fill", accent: .blue)
        ]
        let md = ExportImport.exportMarkdown(tasks: tasks, projects: projects)
        XCTAssertTrue(md.contains("## inbox"))
        XCTAssertTrue(md.contains("## work"))
        XCTAssertTrue(md.contains("- [ ] from inbox"))
        XCTAssertTrue(md.contains("- [ ] from work @work !today"))
    }

    func testMarkdownMarksDoneWithCheckedBox() {
        var t = TaskItem(list: "inbox", title: "finished")
        t.doneAt = Date()
        let md = ExportImport.exportMarkdown(tasks: [t], projects: [])
        XCTAssertTrue(md.contains("- [x] finished"))
    }

    func testMarkdownIndentsNotes() {
        let t = TaskItem(list: "inbox", title: "with note", note: "line 1\nline 2")
        let md = ExportImport.exportMarkdown(tasks: [t], projects: [])
        XCTAssertTrue(md.contains("  > line 1"))
        XCTAssertTrue(md.contains("  > line 2"))
    }

    func testMarkdownSkipsEmptyLists() {
        let projects = [
            ProjectItem(id: "p_empty", name: "empty", icon: "tray", accent: .gray)
        ]
        let md = ExportImport.exportMarkdown(tasks: [], projects: projects)
        XCTAssertFalse(md.contains("empty"))
    }

}
