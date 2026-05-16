import Foundation

/// Runtime configuration for the todarchy MCP server, sourced from
/// environment variables that the MCP client (Claude Desktop, etc.)
/// passes to the binary on invocation.
///
/// Project access is *not* configured here — it lives per-project in
/// the user's main doc, toggled via the in-app "Allow Claude access"
/// context menu. The server reads `claudeAccess` from each project
/// on every call.
struct MCPConfig {
    /// Path to the user's `tasks.automerge` file. Defaults to the
    /// macOS Application Support location the app writes to.
    let fileURL: URL

    /// Author name stamped on comments + (future) audit fields. The
    /// MCP client can override via `TODARCHY_MCP_AUTHOR` if multiple
    /// agents share one binary install.
    let authorName: String

    /// When true, mutating tools refuse to run. Useful while
    /// onboarding — the user can wire the server up and have Claude
    /// read tasks before granting write access.
    let readOnly: Bool

    static func load() -> MCPConfig {
        let env = ProcessInfo.processInfo.environment
        let path = env["TODARCHY_FILE_PATH"] ?? Self.defaultFilePath()
        let author = env["TODARCHY_MCP_AUTHOR"] ?? "Claude"
        let readOnly = env["TODARCHY_MCP_READ_ONLY"] == "1"
        return MCPConfig(
            fileURL: URL(fileURLWithPath: path),
            authorName: author,
            readOnly: readOnly
        )
    }

    /// Mirrors `TaskStorePersistence.defaultFileURL()` — keep these
    /// in sync if the app ever moves its on-disk location.
    private static func defaultFilePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/todarchy/tasks.automerge")
            .path
    }
}
