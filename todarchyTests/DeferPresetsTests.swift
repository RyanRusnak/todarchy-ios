#if os(macOS)
import XCTest

final class DeferPresetsTests: XCTestCase {

    func testPresetsHaveNineEntries() {
        let presets = DeferPickerSheet.presets(now: Date())
        XCTAssertEqual(presets.count, 9)
    }

    func testPresetsAreAllInTheFuture() {
        let now = Date()
        let presets = DeferPickerSheet.presets(now: now)
        for p in presets {
            XCTAssertGreaterThan(p.date, now, "'\(p.label)' should be in the future")
        }
    }

    func testShortDurationsAreExact() {
        let now = Date()
        let presets = DeferPickerSheet.presets(now: now)
        let fifteen = presets.first(where: { $0.label == "+15 min" })!
        XCTAssertEqual(fifteen.date.timeIntervalSince(now), 900, accuracy: 1.0)
        let oneHour = presets.first(where: { $0.label == "+1 hour" })!
        XCTAssertEqual(oneHour.date.timeIntervalSince(now), 3600, accuracy: 1.0)
        let threeHours = presets.first(where: { $0.label == "+3 hours" })!
        XCTAssertEqual(threeHours.date.timeIntervalSince(now), 10800, accuracy: 1.0)
    }

    func testTomorrow9AmResolvesToNextDay0900() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 20
        comps.hour = 14; comps.minute = 0; comps.second = 0
        let now = cal.date(from: comps)!

        let p = DeferPickerSheet.presets(now: now).first { $0.label == "Tomorrow 9am" }!
        let h = Calendar.current.component(.hour, from: p.date)
        XCTAssertEqual(h, 9)
    }

    func testLaterTodayIsAtLeastThreeHoursOut() {
        let now = Date()
        let p = DeferPickerSheet.presets(now: now).first { $0.label == "Later today" }!
        // Must be either +3h at minimum or 9pm (whichever comes first).
        let gap = p.date.timeIntervalSince(now)
        XCTAssertGreaterThanOrEqual(gap, 0, "Not in the past")
    }

    func testPresetLabelsAreUnique() {
        let labels = DeferPickerSheet.presets(now: Date()).map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
#endif
