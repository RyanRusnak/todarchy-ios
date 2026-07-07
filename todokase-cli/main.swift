import Foundation

// todokase — a small keyboard-first CLI for the todokase app.
//
// It operates directly on the local `tasks.automerge` file (the same one
// the app and the MCP server use); the running app sees our atomic write
// and merges it via Automerge. Unlike the MCP server, this is the user's
// own tool on their own machine, so it is NOT restricted to projects with
// "Allow Claude access" — it sees every project, including the inbox.
//
//   todokase add <text> [--project <name>]   add a task (inbox if no flag)
//   todokase list [--project <name>] [--all]  list open tasks
//   todokase next [--project <name>]          the single next task to do

// MARK: - Errors / output

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("todokase: \(message)\n".utf8))
    exit(1)
}

let usage = """
todokase — keyboard-first tasks from your terminal

usage:
  todokase add <text> [--project <name>]    add a task (defaults to inbox)
  todokase list [--project <name>] [--all]  list open tasks
  todokase next [--project <name>]          show the next task to do

<text> uses the same quick-add syntax as the app:
  todokase add "email alice @work !today /ask about the invoice"

flags:
  -p, --project <name>   target / filter a project (omit for inbox)
  -a, --all              include done + deferred tasks (list only)
  -h, --help             show this help
"""

// MARK: - Argument parsing

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { print(usage); exit(0) }

var projectFlag: String?
var showAll = false
var positional: [String] = []

var i = 1
while i < raw.count {
    switch raw[i] {
    case "--project", "-p":
        i += 1
        guard i < raw.count else { die("--project needs a value") }
        projectFlag = raw[i]
    case "--all", "-a":
        showAll = true
    case "--help", "-h":
        print(usage); exit(0)
    default:
        positional.append(raw[i])
    }
    i += 1
}

// MARK: - Doc / helpers

func projectNames(_ snap: TodarchySnapshot) -> [String: String] {
    var m = ["inbox": "inbox"]
    for p in snap.projects { m[p.id] = p.name }
    return m
}

/// Resolve a `--project` value (or nil → inbox) to a stored list id.
func resolveList(_ snap: TodarchySnapshot, flag: String?) -> (id: String, name: String) {
    guard let flag, flag.caseInsensitiveCompare("inbox") != .orderedSame else {
        return ("inbox", "inbox")
    }
    if let p = snap.projects.first(where: { $0.name.caseInsensitiveCompare(flag) == .orderedSame }) {
        return (p.id, p.name)
    }
    let available = (["inbox"] + snap.projects.map { $0.name }).joined(separator: ", ")
    die("no project named '\(flag)'. available: \(available)")
}

/// App-order sort: due tasks first (today → tomorrow → this week), then
/// undated, each group oldest-first by manual position.
func sortForView(_ tasks: [TaskItem]) -> [TaskItem] {
    tasks.sorted { a, b in
        let ao = a.due?.sortOrder ?? Int.max
        let bo = b.due?.sortOrder ?? Int.max
        if ao != bo { return ao < bo }
        return (a.pos ?? a.created) < (b.pos ?? b.created)
    }
}

func formatRow(_ t: TaskItem, names: [String: String], showProject: Bool) -> String {
    var parts = [String(t.id.prefix(6)), t.title]
    if let due = t.due { parts.append("!\(due.rawValue)") }
    if let ctx = t.ctx { parts.append(ctx.rawValue) }
    if showProject { parts.append("(\(names[t.list] ?? t.list))") }
    return parts.joined(separator: "  ")
}

/// Open + not currently deferred (unless `includeAll`).
func visible(_ tasks: [TaskItem], includeAll: Bool, now: Date = Date()) -> [TaskItem] {
    tasks.filter { t in
        if includeAll { return true }
        if t.isDone { return false }
        if let d = t.deferUntil, d > now { return false }
        return true
    }
}

// MARK: - Commands

func runAdd(_ doc: TodarchyDoc) throws {
    let text = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        die("nothing to add. e.g. todokase add \"buy milk @home !today\" --project home")
    }
    let snap = try doc.store.snapshot()
    let list = resolveList(snap, flag: projectFlag)
    let parsed = QuickAddParser.parse(text)
    let title = parsed.title.isEmpty ? text : parsed.title
    let task = TaskItem(
        list: list.id,
        title: title,
        ctx: parsed.ctx,
        note: parsed.note,
        due: parsed.due,
        pos: Date()
    )
    try doc.store.upsertTask(task)
    try doc.save()

    var line = "added  \(title)  →  \(list.name)"
    if let due = parsed.due { line += "  !\(due.rawValue)" }
    if let ctx = parsed.ctx { line += "  \(ctx.rawValue)" }
    print(line)
}

func runList(_ doc: TodarchyDoc) throws {
    let snap = try doc.store.snapshot()
    let names = projectNames(snap)
    var tasks = visible(snap.tasks, includeAll: showAll)
    if let flag = projectFlag {
        let list = resolveList(snap, flag: flag)
        tasks = tasks.filter { $0.list == list.id }
    }
    let sorted = sortForView(tasks)
    guard !sorted.isEmpty else { print("no tasks."); return }
    for t in sorted {
        print(formatRow(t, names: names, showProject: projectFlag == nil))
    }
}

func runNext(_ doc: TodarchyDoc) throws {
    let snap = try doc.store.snapshot()
    let names = projectNames(snap)
    var tasks = visible(snap.tasks, includeAll: false)
    if let flag = projectFlag {
        let list = resolveList(snap, flag: flag)
        tasks = tasks.filter { $0.list == list.id }
    }
    guard let top = sortForView(tasks).first else {
        print("nothing up next — you're clear."); return
    }
    print(formatRow(top, names: names, showProject: true))
    if !top.note.isEmpty, let first = top.note.split(separator: "\n").first {
        print("    \(String(first.prefix(200)))")
    }
}

// MARK: - Dispatch

do {
    let doc = TodarchyDoc(fileURL: MCPConfig.load().fileURL)
    switch command {
    case "add":          try runAdd(doc)
    case "list", "ls":   try runList(doc)
    case "next":         try runNext(doc)
    case "help", "--help", "-h": print(usage)
    default:
        die("unknown command '\(command)'. try: add, list, next  (todokase --help)")
    }
} catch {
    die(error.localizedDescription)
}
