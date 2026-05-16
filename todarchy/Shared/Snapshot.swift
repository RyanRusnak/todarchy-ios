import Foundation

/// Canonical in-memory snapshot of the doc — tasks, projects, and
/// (optionally) the user's context list. Lives at module scope so
/// it's reachable from any target that compiles `Models.swift`,
/// including the MCP CLI (which doesn't pull in Persistence).
///
/// `TaskStorePersistence.Snapshot` is now a typealias for this type
/// — older code that referenced `TaskStorePersistence.Snapshot`
/// keeps working unchanged.
struct TodarchySnapshot: Codable, Equatable {
    var schema: Int = 1
    var tasks: [TaskItem]
    var projects: [ProjectItem]
    /// User's context list. Optional in the wire format so older
    /// snapshots without the field decode cleanly; missing/empty
    /// means "fall back to the built-in seed set" at the call site.
    var contexts: [TaskContext]? = nil

    init(schema: Int = 1,
         tasks: [TaskItem],
         projects: [ProjectItem],
         contexts: [TaskContext]? = nil) {
        self.schema = schema
        self.tasks = tasks
        self.projects = projects
        self.contexts = contexts
    }
}
