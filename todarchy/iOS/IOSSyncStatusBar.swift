#if !os(macOS)
import SwiftUI

/// Compact sync status glyph for the header row. Stays silent (invisible)
/// when everything is healthy — matching iMessage / Mail's "only speak
/// when something's wrong" pattern. Tap to jump into Settings → Sync
/// for details + manual refresh.
struct IOSSyncHeaderIndicator: View {
    @ObservedObject var sync = SyncSettings.shared
    var onTap: () -> Void

    private enum Kind { case localOnly, syncing, error, synced }

    private var kind: Kind {
        if sync.syncFolderURL == nil { return .localOnly }
        if sync.isSyncing { return .syncing }
        if sync.lastSyncError != nil { return .error }
        return .synced
    }

    var body: some View {
        Button(action: onTap) {
            glyph(for: kind)
                // Small visual, larger invisible hit area so it's still
                // comfortably tappable.
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: kind))
    }

    @ViewBuilder
    private func glyph(for kind: Kind) -> some View {
        switch kind {
        case .localOnly:
            // Hollow circle: "nothing is syncing, you're on-device only".
            Circle()
                .stroke(Theme.fgMute, lineWidth: 1.2)
                .frame(width: 8, height: 8)
        case .syncing:
            ProgressView().controlSize(.mini).tint(Theme.accent)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.danger)
        case .synced:
            // Solid green: "synced and healthy".
            Circle()
                .fill(Theme.success)
                .frame(width: 8, height: 8)
        }
    }

    private func borderTint(for kind: Kind) -> Color {
        kind == .error ? Theme.danger.opacity(0.5) : Theme.border
    }

    private func accessibilityLabel(for kind: Kind) -> String {
        switch kind {
        case .localOnly: return "Local only — tap to set up sync"
        case .syncing: return "Syncing"
        case .error: return "Sync error — tap for details"
        case .synced: return "Synced"
        }
    }
}

/// Legacy bottom status bar — kept for iPad sidebar use where the extra
/// width makes a persistent strip fine. Phone layout uses the compact
/// header indicator above instead.
struct IOSSyncStatusBar: View {
    @ObservedObject var sync = SyncSettings.shared
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                leadIndicator
                mainLabel
                Spacer(minLength: 4)
                trailLabel
            }
            .font(Typo.mono(11))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadIndicator: some View {
        if sync.syncFolderURL == nil {
            Circle().fill(Theme.fgFaint).frame(width: 6, height: 6)
        } else if sync.isSyncing {
            ProgressView().controlSize(.mini).tint(Theme.accent)
        } else if sync.lastSyncError != nil {
            Circle().fill(Theme.danger).frame(width: 6, height: 6)
        } else {
            Circle().fill(Theme.success).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var mainLabel: some View {
        if sync.syncFolderURL == nil {
            Text("local only").foregroundStyle(Theme.fgMute)
        } else if sync.isSyncing {
            Text("syncing…").foregroundStyle(Theme.accent)
        } else if let err = sync.lastSyncError {
            Text(err)
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        } else {
            Text("synced")
                .foregroundStyle(Theme.success)
        }
    }

    @ViewBuilder
    private var trailLabel: some View {
        if sync.syncFolderURL != nil {
            HStack(spacing: 4) {
                if let ts = sync.lastMergedAt {
                    Text(relative(ts))
                        .foregroundStyle(Theme.fgFaint)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.fgFaint)
            }
        } else {
            HStack(spacing: 4) {
                Text("set up")
                    .foregroundStyle(Theme.accent)
                    .font(Typo.mono(10, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.fgFaint)
            }
        }
    }

    private var background: some View {
        Group {
            if sync.lastSyncError != nil {
                Theme.danger.opacity(0.1)
            } else {
                Theme.bgElev
            }
        }
    }

    /// "12s ago", "5m ago", "2h ago". Falls back to a short absolute time
    /// if it's been a day or more.
    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }
}
#endif
