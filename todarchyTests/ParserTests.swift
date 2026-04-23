import XCTest

final class ParserTests: XCTestCase {
    func testPlainTitle() {
        let r = QuickAddParser.parse("buy milk")
        XCTAssertEqual(r.title, "buy milk")
        XCTAssertNil(r.ctx)
        XCTAssertNil(r.due)
        XCTAssertEqual(r.note, "")
    }

    func testContextOnly() {
        let r = QuickAddParser.parse("call mom @phone")
        XCTAssertEqual(r.title, "call mom")
        XCTAssertEqual(r.ctx, .phone)
    }

    func testDueToday() {
        let r = QuickAddParser.parse("submit report !today")
        XCTAssertEqual(r.title, "submit report")
        XCTAssertEqual(r.due, .today)
    }

    func testDueWeekMapsToThisWeek() {
        let r = QuickAddParser.parse("gym !week")
        XCTAssertEqual(r.due, .thisWeek)
    }

    func testNoteAfterSlash() {
        let r = QuickAddParser.parse("pick up kids /from daycare at 5")
        XCTAssertEqual(r.title, "pick up kids")
        XCTAssertEqual(r.note, "from daycare at 5")
    }

    func testAllTokensCombined() {
        let r = QuickAddParser.parse("call mom @phone !today /remember to ask about flights")
        XCTAssertEqual(r.title, "call mom")
        XCTAssertEqual(r.ctx, .phone)
        XCTAssertEqual(r.due, .today)
        XCTAssertEqual(r.note, "remember to ask about flights")
    }

    func testDueIsCaseInsensitive() {
        let r = QuickAddParser.parse("x !TOMORROW")
        XCTAssertEqual(r.due, .tomorrow)
    }

    func testUnknownContextAccepted() {
        let r = QuickAddParser.parse("do stuff @banana")
        // Contexts are user-editable now — any @word is valid.
        XCTAssertEqual(r.title, "do stuff")
        XCTAssertEqual(r.ctx, TaskContext(rawValue: "@banana"))
    }

    func testWhitespaceCollapsed() {
        let r = QuickAddParser.parse("  multiple   spaces   here  ")
        XCTAssertEqual(r.title, "multiple spaces here")
    }
}
