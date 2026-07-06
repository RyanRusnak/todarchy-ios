import Foundation

/// Parses natural-language defer expressions like `tomorrow`, `+3d`, `+1w`,
/// `mon`-`sun`, `YYYY-MM-DD`. All resolved dates land at 09:00 local time.
enum DeferParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        var cal = calendar
        cal.timeZone = calendar.timeZone

        // today / tomorrow
        if s == "today" {
            return atNine(cal.startOfDay(for: now), cal: cal)
        }
        if s == "tomorrow" || s == "tmrw" {
            guard let t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return nil }
            return atNine(t, cal: cal)
        }

        // +Nd / +Nw / +Nm
        if s.hasPrefix("+"),
           let last = s.last,
           let n = Int(s.dropFirst().dropLast()) {
            let component: Calendar.Component
            switch last {
            case "d": component = .day
            case "w": component = .weekOfYear
            case "m": component = .month
            default: return nil
            }
            guard let added = cal.date(byAdding: component, value: n, to: cal.startOfDay(for: now)) else { return nil }
            return atNine(added, cal: cal)
        }

        // Weekday abbreviations → next occurrence.
        let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        if let target = weekdays[String(s.prefix(3))] {
            var comps = DateComponents()
            comps.weekday = target
            comps.hour = 9
            comps.minute = 0
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        }

        // ISO date YYYY-MM-DD
        if s.count == 10, s[s.index(s.startIndex, offsetBy: 4)] == "-" {
            let df = DateFormatter()
            df.calendar = cal
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = cal.timeZone
            if let parsed = df.date(from: s) {
                return atNine(parsed, cal: cal)
            }
        }

        // `this weekend` = next Saturday 09:00
        if s == "this weekend" || s == "weekend" {
            var comps = DateComponents()
            comps.weekday = 7
            comps.hour = 9
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        }

        // `next week` = next Monday 09:00
        if s == "next week" {
            var comps = DateComponents()
            comps.weekday = 2
            comps.hour = 9
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        }

        return nil
    }

    /// The canonical "tomorrow" defer target: the start of the next day at
    /// 09:00 local time. Quick-defer actions use this so a task deferred late
    /// in the day resurfaces tomorrow morning — after midnight — rather than a
    /// raw 24-hour offset that would land at the same clock time tomorrow.
    static func tomorrow(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.timeZone = calendar.timeZone
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        return startOfTomorrow.flatMap { atNine($0, cal: cal) }
            ?? now.addingTimeInterval(24 * 3600)
    }

    private static func atNine(_ date: Date, cal: Calendar) -> Date? {
        cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)
    }
}
