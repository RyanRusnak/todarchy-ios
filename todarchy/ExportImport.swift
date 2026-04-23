import Foundation

/// Read-only serializers/deserializers for sharing a store's tasks with other
/// devices or apps. JSON is round-trippable; Markdown is export-only (human-
/// readable checklist).
enum ExportImport {

    // MARK: - JSON

    static func exportJSON(tasks: [TaskItem], projects: [ProjectItem]) throws -> Data {
        let snap = TaskStorePersistence.Snapshot(tasks: tasks, projects: projects)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(snap)
    }

    static func importJSON(_ data: Data) throws -> TaskStorePersistence.Snapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return try dec.decode(TaskStorePersistence.Snapshot.self, from: data)
    }

    // MARK: - Markdown

    /// Group tasks by list and render each as a Markdown `## heading` followed
    /// by `- [ ]` / `- [x]` lines. Notes appear as indented `> ` quotes.
    static func exportMarkdown(
        tasks: [TaskItem],
        projects: [ProjectItem],
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("# todarchy — \(Self.iso(now))")
        lines.append("")

        func heading(for listId: String) -> String {
            if listId == "inbox" { return "inbox" }
            return projects.first(where: { $0.id == listId })?.name ?? listId
        }

        let listIds = (["inbox"] + projects.map(\.id))
        for listId in listIds {
            let forList = tasks.filter { $0.list == listId }
            if forList.isEmpty { continue }
            lines.append("## \(heading(for: listId))")
            lines.append("")
            for task in forList {
                let box = task.isDone ? "[x]" : "[ ]"
                var title = task.title
                if let ctx = task.ctx { title += " \(ctx.rawValue)" }
                if let due = task.due { title += " !\(due.label)" }
                lines.append("- \(box) \(title)")
                if !task.note.isEmpty {
                    for line in task.note.split(separator: "\n") {
                        lines.append("  > \(line)")
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
