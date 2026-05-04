import SwiftUI

/// Dense debug panel that exposes the raw state behind sync: file path,
/// file mtime, file size, task count, last sync result, device id. Used
/// when triaging "why aren't my tasks syncing?" reports — the user can
/// screenshot this and it tells the whole story.
struct SyncDiagnosticsView: View {
    @ObservedObject var settings = SyncSettings.shared
    @State private var refreshTick: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("DEVICE")
                row("id", DeviceID.current)
                row("name", DeviceID.humanReadable)

                sectionHeader("FILE")
                row("path", TaskStorePersistence.shared.fileURL.path)
                row("exists", fileExists ? "yes" : "no")
                row("size", fileSize)
                row("modified", fileModified)

                sectionHeader("DOC")
                row("tasks in memory", "\(taskCount)")
                row("projects in memory", "\(projectCount)")

                sectionHeader("SYNC STATUS")
                row("mode", modeLabel)
                if case .folder(let url) = settings.mode {
                    row("folder", url.path)
                }
                if case .server(let cfg) = settings.mode {
                    row("server url", cfg.baseURL.absoluteString)
                    row("server id", cfg.mainDocId)
                    row("server health", healthLabel)
                }
                row("last merged", settings.lastMergedAt?.formatted() ?? "never")
                row("last error", settings.lastSyncError ?? "—")
                row("currently syncing", settings.isSyncing ? "yes" : "no")

                Button("Refresh") {
                    refreshTick = Date()
                }
                .font(Typo.mono(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 6)
            }
            .padding(20)
            .id(refreshTick)   // force re-read file attrs when Refresh tapped
        }
        .background(Theme.bg)
    }

    // MARK: - Computed

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: TaskStorePersistence.shared.fileURL.path)
    }

    private var fileSize: String {
        let url = TaskStorePersistence.shared.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return "—" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }

    private var fileModified: String {
        let url = TaskStorePersistence.shared.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "—" }
        let delta = Date().timeIntervalSince(date)
        if delta < 5 { return "just now (\(date.formatted(date: .omitted, time: .standard)))" }
        if delta < 60 { return "\(Int(delta))s ago (\(date.formatted(date: .omitted, time: .standard)))" }
        if delta < 3600 { return "\(Int(delta / 60))m ago (\(date.formatted(date: .omitted, time: .standard)))" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago (\(date.formatted(date: .abbreviated, time: .shortened)))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var modeLabel: String {
        switch settings.mode {
        case .localOnly: return "local only"
        case .folder:    return "folder"
        case .server:    return "server"
        }
    }

    private var healthLabel: String {
        switch settings.serverHealth {
        case .unknown: return "unknown"
        case .ok:      return "ok"
        case .failing(let m): return "failing — \(m)"
        }
    }

    private var taskCount: Int {
        (TaskStorePersistence.shared.load()?.tasks.count) ?? 0
    }

    private var projectCount: Int {
        (TaskStorePersistence.shared.load()?.projects.count) ?? 0
    }

    // MARK: - Layout

    private func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(Typo.mono(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.fgMute)
            .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: any StringProtocol) -> some View {
        row(label, String(value))
    }
}
