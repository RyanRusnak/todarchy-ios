#if os(macOS)
import Foundation
import AppKit
import UniformTypeIdentifiers

/// AppKit wrappers that drive the open/save panels for export/import commands.
enum ExportImportActions {
    static func exportJSON(store: TaskStore) {
        let panel = NSSavePanel()
        panel.title = "Export todokase tasks"
        panel.nameFieldStringValue = "todarchy-\(isoDay()).todarchy"
        panel.allowedContentTypes = [UTType.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ExportImport.exportJSON(tasks: store.tasks, projects: store.projects)
            try data.write(to: url, options: .atomic)
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    static func exportMarkdown(store: TaskStore) {
        let panel = NSSavePanel()
        panel.title = "Export as Markdown"
        panel.nameFieldStringValue = "todarchy-\(isoDay()).md"
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ExportImport.exportMarkdown(tasks: store.tasks, projects: store.projects)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    static func importJSON(store: TaskStore) {
        let panel = NSOpenPanel()
        panel.title = "Import todokase tasks"
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let snap = try ExportImport.importJSON(data)
            store.replaceAll(tasks: snap.tasks, projects: snap.projects)
        } catch {
            alert("Import failed", error.localizedDescription)
        }
    }

    private static func isoDay() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension TaskStore {
    /// Replace the entire store contents. Used by import; pushes an undo
    /// snapshot first so a mis-clicked import can be recovered.
    func replaceAll(tasks: [TaskItem], projects: [ProjectItem]) {
        snapshot()
        self.projects = projects
        self.tasks = tasks
        self.selectedTaskId = nil
        self.editingTaskId = nil
    }
}
#endif
