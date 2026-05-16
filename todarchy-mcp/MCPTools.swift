import Foundation

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var descriptor: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

enum MCPTools {
    static let all: [MCPTool] = [
        listTasksTool,
        getTaskTool,
        addTaskTool,
        completeTaskTool,
        addCommentTool,
    ]

    static func call(params: [String: Any], config: MCPConfig) throws -> Any {
        guard let name = params["name"] as? String else {
            throw MCPError(code: -32602, message: "tools/call requires `name`")
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        let doc = TodarchyDoc(fileURL: config.fileURL)

        let text: String
        switch name {
        case "list_tasks":
            text = try handleListTasks(args: args, doc: doc)
        case "get_task":
            text = try handleGetTask(args: args, doc: doc)
        case "add_task":
            try requireWritable(config)
            text = try handleAddTask(args: args, doc: doc)
        case "complete_task":
            try requireWritable(config)
            text = try handleCompleteTask(args: args, doc: doc)
        case "add_comment":
            try requireWritable(config)
            text = try handleAddComment(args: args, doc: doc, config: config)
        default:
            throw MCPError(code: -32601, message: "Unknown tool: \(name)")
        }

        return ["content": [["type": "text", "text": text]]]
    }

    private static func requireWritable(_ config: MCPConfig) throws {
        if config.readOnly {
            throw MCPError(
                code: -32000,
                message: "MCP server is read-only. Unset TODARCHY_MCP_READ_ONLY to enable mutations."
            )
        }
    }

    // MARK: - Tool descriptors

    private static let listTasksTool = MCPTool(
        name: "list_tasks",
        description: """
        List tasks across the user's todarchy projects that have Claude \
        access enabled (via the in-app "Allow Claude access" toggle on \
        a project's context menu). Projects without the flag are \
        invisible to this server.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string",
                    "enum": ["open", "done", "all"],
                    "default": "open",
                    "description": "Filter by task status. Defaults to open."
                ],
                "project": [
                    "type": "string",
                    "description": "Optional: filter to a single project by exact name."
                ]
            ]
        ]
    )

    private static let getTaskTool = MCPTool(
        name: "get_task",
        description: """
        Fetch a single task by id, including the markdown body and the \
        full comment thread. Task must be in a Claude-accessible project.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Task id."]
            ],
            "required": ["id"]
        ]
    )

    private static let addTaskTool = MCPTool(
        name: "add_task",
        description: """
        Create a new task in a Claude-accessible project. Returns the \
        new task's id.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "project": [
                    "type": "string",
                    "description": "Target project name. Must have Claude access enabled."
                ],
                "title": ["type": "string", "description": "Task title."],
                "body": [
                    "type": "string",
                    "default": "",
                    "description": "Optional task body / details (markdown)."
                ]
            ],
            "required": ["project", "title"]
        ]
    )

    private static let completeTaskTool = MCPTool(
        name: "complete_task",
        description: "Mark a task as done. Task must be in a Claude-accessible project.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Task id."]
            ],
            "required": ["id"]
        ]
    )

    private static let addCommentTool = MCPTool(
        name: "add_comment",
        description: """
        Append a comment to a task. Author defaults to "Claude"; the \
        TODARCHY_MCP_AUTHOR env var on the binary overrides. Task must \
        be in a Claude-accessible project.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "task_id": ["type": "string", "description": "Task id."],
                "text": ["type": "string", "description": "Comment body (plain text)."]
            ],
            "required": ["task_id", "text"]
        ]
    )

    // MARK: - Handlers

    private static func handleListTasks(args: [String: Any], doc: TodarchyDoc) throws -> String {
        let status = (args["status"] as? String) ?? "open"
        let projectFilter = args["project"] as? String

        let snap = try doc.store.snapshot()
        let accessible: Set<String> = Set(snap.projects.filter { $0.claudeAccess }.map { $0.id })
        let projectsById: [String: ProjectItem] = Dictionary(
            uniqueKeysWithValues: snap.projects.map { ($0.id, $0) }
        )

        let tasks = snap.tasks.filter { task in
            guard accessible.contains(task.list) else { return false }
            switch status {
            case "open": if task.isDone { return false }
            case "done": if !task.isDone { return false }
            default: break   // "all"
            }
            if let projectFilter, projectsById[task.list]?.name != projectFilter {
                return false
            }
            return true
        }

        let items = tasks.map { task -> [String: Any] in
            var d: [String: Any] = [
                "id": task.id,
                "title": task.title,
                "project": projectsById[task.list]?.name ?? task.list,
                "isDone": task.isDone,
                "created": ISO8601DateFormatter().string(from: task.created),
            ]
            if let due = task.due { d["due"] = due.rawValue }
            if let ctx = task.ctx { d["ctx"] = ctx.rawValue }
            if !task.note.isEmpty {
                d["bodyPreview"] = String(task.note.prefix(120))
            }
            if !task.comments.isEmpty {
                d["commentCount"] = task.comments.count
            }
            return d
        }
        return try jsonString(items)
    }

    private static func handleGetTask(args: [String: Any], doc: TodarchyDoc) throws -> String {
        guard let id = args["id"] as? String else {
            throw MCPError(code: -32602, message: "id is required")
        }
        let snap = try doc.store.snapshot()
        let accessible: Set<String> = Set(snap.projects.filter { $0.claudeAccess }.map { $0.id })

        guard let task = snap.tasks.first(where: { $0.id == id }) else {
            throw MCPError(code: -32000, message: "Task not found: \(id)")
        }
        guard accessible.contains(task.list) else {
            throw MCPError(code: -32000, message: "Task is in a project without Claude access.")
        }
        let projectName = snap.projects.first(where: { $0.id == task.list })?.name ?? task.list

        var d: [String: Any] = [
            "id": task.id,
            "title": task.title,
            "project": projectName,
            "isDone": task.isDone,
            "body": task.note,
            "created": ISO8601DateFormatter().string(from: task.created),
            "comments": task.comments.map { c -> [String: Any] in
                [
                    "author": c.author,
                    "text": c.text,
                    "createdAt": ISO8601DateFormatter().string(from: c.createdAt)
                ]
            }
        ]
        if let due = task.due { d["due"] = due.rawValue }
        if let ctx = task.ctx { d["ctx"] = ctx.rawValue }
        if let doneAt = task.doneAt {
            d["doneAt"] = ISO8601DateFormatter().string(from: doneAt)
        }
        return try jsonString(d)
    }

    private static func handleAddTask(args: [String: Any], doc: TodarchyDoc) throws -> String {
        guard let projectName = args["project"] as? String else {
            throw MCPError(code: -32602, message: "project is required")
        }
        guard let title = args["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError(code: -32602, message: "title is required")
        }
        let body = (args["body"] as? String) ?? ""

        let snap = try doc.store.snapshot()
        guard let project = snap.projects.first(where: { $0.name == projectName }) else {
            throw MCPError(code: -32000, message: "Project not found: \(projectName)")
        }
        guard project.claudeAccess else {
            throw MCPError(
                code: -32000,
                message: "Project '\(projectName)' doesn't have Claude access enabled."
            )
        }

        let task = TaskItem(
            list: project.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: body,
            pos: Date()
        )
        try doc.store.upsertTask(task)
        try doc.save()
        return "Created task \(task.id) in '\(projectName)'."
    }

    private static func handleCompleteTask(args: [String: Any], doc: TodarchyDoc) throws -> String {
        guard let id = args["id"] as? String else {
            throw MCPError(code: -32602, message: "id is required")
        }
        let snap = try doc.store.snapshot()
        let accessible: Set<String> = Set(snap.projects.filter { $0.claudeAccess }.map { $0.id })

        guard var task = snap.tasks.first(where: { $0.id == id }) else {
            throw MCPError(code: -32000, message: "Task not found: \(id)")
        }
        guard accessible.contains(task.list) else {
            throw MCPError(code: -32000, message: "Task is in a project without Claude access.")
        }
        if task.isDone {
            return "Task \(id) is already done."
        }
        task.doneAt = Date()
        try doc.store.upsertTask(task)
        try doc.save()
        return "Completed task \(id)."
    }

    private static func handleAddComment(args: [String: Any],
                                          doc: TodarchyDoc,
                                          config: MCPConfig) throws -> String {
        guard let taskId = args["task_id"] as? String else {
            throw MCPError(code: -32602, message: "task_id is required")
        }
        guard let text = args["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError(code: -32602, message: "text is required")
        }
        let snap = try doc.store.snapshot()
        let accessible: Set<String> = Set(snap.projects.filter { $0.claudeAccess }.map { $0.id })

        guard var task = snap.tasks.first(where: { $0.id == taskId }) else {
            throw MCPError(code: -32000, message: "Task not found: \(taskId)")
        }
        guard accessible.contains(task.list) else {
            throw MCPError(code: -32000, message: "Task is in a project without Claude access.")
        }
        let comment = Comment(author: config.authorName,
                              text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        task.comments.append(comment)
        try doc.store.upsertTask(task)
        try doc.save()
        return "Posted comment \(comment.id) by \(config.authorName) on task \(taskId)."
    }

    private static func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }
}
