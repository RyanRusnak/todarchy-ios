import SwiftUI

/// Shared UI pieces for the sync settings page. Used by both macOS Settings
/// and the iOS settings sheet.

struct SyncStatusBlock: View {
    @ObservedObject var settings: SyncSettings

    var body: some View {
        if let url = settings.syncFolderURL {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if settings.isSyncing {
                        ProgressView().controlSize(.small)
                        Text("syncing…")
                            .font(Typo.mono(13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    } else if settings.lastSyncError != nil {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text("sync failed")
                            .font(Typo.mono(13, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Circle().fill(Theme.success).frame(width: 8, height: 8)
                        Text("syncing")
                            .font(Typo.mono(13, weight: .semibold))
                            .foregroundStyle(Theme.success)
                    }
                }
                Text(displayPath(url))
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgDim)
                    .textSelection(.enabled)
                    .lineLimit(3)
                if let err = settings.lastSyncError {
                    Text(err)
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                }
                if let ts = settings.lastMergedAt {
                    Text("last merged: \(ts.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgFaint)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.fgFaint).frame(width: 8, height: 8)
                    Text("local only")
                        .font(Typo.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.fgMute)
                }
                Text(displayPath(TaskStorePersistence.defaultFileURL()))
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgFaint)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    /// Abbreviate `/Users/me/...` to `~/...` on macOS and elide
    /// iOS sandbox prefixes.
    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
        if let iCloudRange = path.range(of: "Mobile Documents/com~apple~CloudDocs/") {
            return "iCloud Drive/" + String(path[iCloudRange.upperBound...])
        }
        return path
    }
}

struct SyncExplanation: View {
    var body: some View {
        Text("Pick a folder that's already synced across your devices — iCloud Drive, Dropbox, Syncthing — and todarchy will mirror the same tasks.automerge file there. The Linux, Mac, and iOS apps all read and write the same file.")
            .font(Typo.mono(11))
            .foregroundStyle(Theme.fgMute)
            .fixedSize(horizontal: false, vertical: true)
    }
}
