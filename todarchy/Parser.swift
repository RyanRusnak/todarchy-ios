import Foundation

struct ParsedQuickAdd {
    var title: String
    var ctx: TaskContext?
    var due: DueBucket?
    var note: String
}

enum QuickAddParser {
    static func parse(_ raw: String) -> ParsedQuickAdd {
        var title = raw
        var ctx: TaskContext?
        var due: DueBucket?
        var note = ""

        // Context: @word
        if let range = title.range(of: #"@[A-Za-z]+"#, options: .regularExpression) {
            let token = String(title[range]).lowercased()
            ctx = TaskContext(rawValue: token)
            title.removeSubrange(range)
        }

        // Due: !today | !tomorrow | !week
        if let range = title.range(of: #"!(today|tomorrow|week)"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            let token = String(title[range]).lowercased()
            switch token {
            case "!today": due = .today
            case "!tomorrow": due = .tomorrow
            case "!week": due = .thisWeek
            default: break
            }
            title.removeSubrange(range)
        }

        // Note: " /rest"
        if let range = title.range(of: #"\s/(.+)$"#, options: .regularExpression) {
            note = String(title[range]).trimmingCharacters(in: .whitespaces)
            if note.hasPrefix("/") { note.removeFirst() }
            note = note.trimmingCharacters(in: .whitespaces)
            title.removeSubrange(range)
        }

        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return ParsedQuickAdd(title: title, ctx: ctx, due: due, note: note)
    }
}
