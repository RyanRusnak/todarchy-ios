import XCTest

final class DeferParserTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = day
        comps.hour = h; comps.minute = min; comps.second = 0
        return cal.date(from: comps)!
    }

    func testTodayParsesTo0900() {
        let now = d(2026, 4, 20, 14, 30)
        let parsed = DeferParser.parse("today", now: now, calendar: cal)
        XCTAssertEqual(parsed, d(2026, 4, 20, 9, 0))
    }

    func testTomorrow() {
        let now = d(2026, 4, 20, 14, 30)
        XCTAssertEqual(DeferParser.parse("tomorrow", now: now, calendar: cal),
                       d(2026, 4, 21, 9, 0))
    }

    func testTmrwAlias() {
        let now = d(2026, 4, 20)
        XCTAssertEqual(DeferParser.parse("tmrw", now: now, calendar: cal),
                       d(2026, 4, 21, 9, 0))
    }

    func testPlusDays() {
        let now = d(2026, 4, 20, 14)
        XCTAssertEqual(DeferParser.parse("+3d", now: now, calendar: cal),
                       d(2026, 4, 23, 9, 0))
    }

    func testPlusWeeks() {
        let now = d(2026, 4, 20, 14)
        XCTAssertEqual(DeferParser.parse("+2w", now: now, calendar: cal),
                       d(2026, 5, 4, 9, 0))
    }

    func testPlusMonth() {
        let now = d(2026, 4, 20, 14)
        XCTAssertEqual(DeferParser.parse("+1m", now: now, calendar: cal),
                       d(2026, 5, 20, 9, 0))
    }

    func testWeekdayNextOccurrence() {
        // 2026-04-20 is a Monday. "fri" should resolve to 2026-04-24 09:00.
        let now = d(2026, 4, 20, 10)
        XCTAssertEqual(DeferParser.parse("fri", now: now, calendar: cal),
                       d(2026, 4, 24, 9, 0))
    }

    func testWeekdaySunday() {
        let now = d(2026, 4, 20, 10)
        XCTAssertEqual(DeferParser.parse("sun", now: now, calendar: cal),
                       d(2026, 4, 26, 9, 0))
    }

    func testISODate() {
        let now = d(2026, 4, 20)
        XCTAssertEqual(DeferParser.parse("2026-05-01", now: now, calendar: cal),
                       d(2026, 5, 1, 9, 0))
    }

    func testThisWeekendResolvesToSaturday() {
        // Monday 2026-04-20 → next Sat = 2026-04-25.
        let now = d(2026, 4, 20, 10)
        XCTAssertEqual(DeferParser.parse("this weekend", now: now, calendar: cal),
                       d(2026, 4, 25, 9, 0))
    }

    func testNextWeekResolvesToNextMonday() {
        let now = d(2026, 4, 20, 10)   // this monday
        XCTAssertEqual(DeferParser.parse("next week", now: now, calendar: cal),
                       d(2026, 4, 27, 9, 0))
    }

    func testInvalidReturnsNil() {
        let now = d(2026, 4, 20)
        XCTAssertNil(DeferParser.parse("banana", now: now, calendar: cal))
        XCTAssertNil(DeferParser.parse("+xd", now: now, calendar: cal))
        XCTAssertNil(DeferParser.parse("", now: now, calendar: cal))
        XCTAssertNil(DeferParser.parse("2026/05/01", now: now, calendar: cal))
    }

    func testCaseInsensitive() {
        let now = d(2026, 4, 20)
        XCTAssertNotNil(DeferParser.parse("TOMORROW", now: now, calendar: cal))
        XCTAssertNotNil(DeferParser.parse("FrI", now: now, calendar: cal))
    }

    func testWhitespaceTrimmed() {
        let now = d(2026, 4, 20)
        XCTAssertEqual(DeferParser.parse("  tomorrow  ", now: now, calendar: cal),
                       d(2026, 4, 21, 9, 0))
    }

    // MARK: - tomorrow() quick-defer helper

    func testTomorrowHelperLandsAfterMidnightNotPlus24h() {
        // Deferring at 22:00 must resurface tomorrow at 09:00 (after
        // midnight), NOT 22:00 tomorrow (a raw 24-hour offset).
        let now = d(2026, 4, 20, 22, 0)
        XCTAssertEqual(DeferParser.tomorrow(now: now, calendar: cal),
                       d(2026, 4, 21, 9, 0))
    }

    func testTomorrowHelperFromEarlyMorning() {
        // Even deferring at 01:00 lands on the *next* day, not today.
        let now = d(2026, 4, 20, 1, 0)
        XCTAssertEqual(DeferParser.tomorrow(now: now, calendar: cal),
                       d(2026, 4, 21, 9, 0))
    }
}
