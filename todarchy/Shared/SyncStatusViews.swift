import SwiftUI

/// Shared UI pieces for the sync settings page. Used by both macOS Settings
/// and the iOS settings sheet.

struct SyncStatusBlock: View {
    @ObservedObject var settings: SyncSettings

    var body: some View {
        switch settings.mode {
        case .folder(let url):
            folderStatus(url)
        case .server(let cfg):
            serverStatus(cfg)
        case .localOnly:
            localOnlyStatus
        }
    }

    private func folderStatus(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine(
                activeLabel: "syncing",
                idlePath: displayPath(url),
                activeColor: Theme.success
            )
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
    }

    private func serverStatus(_ cfg: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch settings.serverHealth {
                case .ok:
                    Circle().fill(Theme.success).frame(width: 8, height: 8)
                    Text("server reachable")
                        .font(Typo.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.success)
                case .failing:
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    Text("server error")
                        .font(Typo.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                case .unknown:
                    Circle().fill(Theme.fgFaint).frame(width: 8, height: 8)
                    Text("server")
                        .font(Typo.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.fgDim)
                }
            }
            Text(cfg.baseURL.absoluteString)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgDim)
                .textSelection(.enabled)
                .lineLimit(2)
            Text("id: \(cfg.mainDocId)")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgMute)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .failing(let message) = settings.serverHealth {
                Text(message)
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
    }

    private var localOnlyStatus: some View {
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

    @ViewBuilder
    private func statusLine(activeLabel: String, idlePath: String, activeColor: Color) -> some View {
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
                Circle().fill(activeColor).frame(width: 8, height: 8)
                Text(activeLabel)
                    .font(Typo.mono(13, weight: .semibold))
                    .foregroundStyle(activeColor)
            }
        }
    }

    /// Abbreviate `/Users/me/...` to `~/...` on macOS and elide iCloud prefixes.
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Folder: mirror tasks.automerge through iCloud Drive, Dropbox, or Syncthing — all your devices read and write the same file.")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)
            Text("Server: push encrypted bytes to a todarchy relay. Share the same sync id across devices to sync; the server never sees plaintext.")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
