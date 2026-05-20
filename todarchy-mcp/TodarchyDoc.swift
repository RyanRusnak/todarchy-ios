import Foundation

/// One-shot wrapper around `AutomergeStore` for the MCP server's
/// read-mutate-write cycle. Opens the user's `tasks.automerge` from
/// disk, exposes the same `AutomergeStore` API the app uses, then
/// writes back atomically.
///
/// The running app's `DispatchSourceFileSystemObject` watcher sees
/// our atomic rename and merges via Automerge — concurrent edits
/// between Claude and the running app converge through the CRDT.
final class TodarchyDoc {
    let fileURL: URL
    let store: AutomergeStore

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            self.store = AutomergeStore(data: data)
        } else {
            // No file yet (fresh install / wrong path) — fall back to
            // an empty doc. Most tools will then return empty results
            // or errors; the user can fix the path via env var.
            self.store = AutomergeStore()
        }
    }

    /// Atomic save: re-read disk + merge any changes the app wrote
    /// between our init and now, then write the merged bytes via
    /// `.tmp` sibling + rename. Same pattern as
    /// `TaskStorePersistence.writeBytes` so the app's file watcher
    /// picks it up the same way.
    ///
    /// The pre-write merge is load-bearing: without it, the running
    /// app could write a new task between our init and our save, and
    /// our write would broadcast a file missing that task. Other
    /// readers (peer devices syncing from a folder) would briefly see
    /// the inconsistent state before the next sync round repaired it.
    /// Automerge being a CRDT bounds the damage — but pulling the
    /// latest bytes here means the file is internally consistent
    /// from the moment we write it.
    func save() throws {
        if let onDisk = try? Data(contentsOf: fileURL) {
            let other = AutomergeStore(data: onDisk)
            try? store.merge(other)
        }
        let bytes = store.save()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = fileURL.appendingPathExtension("tmp")
        try bytes.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
