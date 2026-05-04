#if os(macOS)
import SwiftUI

struct MacStatusBar: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject var sync = SyncSettings.shared
    let vimMode: VimMode

    var body: some View {
        HStack(spacing: 10) {
            modeBlock
            Text(leftLabel)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgDim)
            divider
            Text("inbox \(store.countOpen(in: "inbox"))")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Text("projects \(store.projects.count)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Text("active \(totalOpen)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)

            Spacer()

            Text("\(cursorIndex):\(store.viewTasks.count)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            divider
            Text("utf-8").font(Typo.mono(11)).foregroundStyle(Theme.fgFaint)
            divider
            syncIndicator
            divider
            Text("todarchy")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 26)
        .background(Theme.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var syncIndicator: some View {
        if sync.mode.kind == .localOnly {
            Circle().fill(Theme.fgFaint).frame(width: 6, height: 6)
            Text("local only").font(Typo.mono(11)).foregroundStyle(Theme.fgMute)
        } else if sync.isSyncing {
            ProgressView().controlSize(.mini)
            Text("syncing").font(Typo.mono(11)).foregroundStyle(Theme.accent)
        } else if sync.lastSyncError != nil {
            Circle().fill(Theme.danger).frame(width: 6, height: 6)
            Text("sync failed").font(Typo.mono(11)).foregroundStyle(Theme.danger)
                .help(sync.lastSyncError ?? "")
        } else {
            Circle().fill(Theme.success).frame(width: 6, height: 6)
            Text("synced").font(Typo.mono(11)).foregroundStyle(Theme.success)
        }
    }

    private var modeBlock: some View {
        Text(vimMode.rawValue)
            .font(Typo.mono(10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(vimMode.color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 12)
    }

    private var leftLabel: String {
        if let c = store.activeContextFilter { return "~/ctx/\(c.rawValue)" }
        if case .list(let id) = store.activeSelection {
            let name = store.project(id: id)?.name ?? id
            return "~/tasks/\(name)"
        }
        return "~/tasks"
    }

    private var totalOpen: Int {
        store.tasks.filter { !$0.isDone && !$0.isDeferred }.count
    }

    private var cursorIndex: Int {
        guard let sid = store.selectedTaskId,
              let idx = store.viewTasks.firstIndex(where: { $0.id == sid }) else { return 0 }
        return idx + 1
    }
}
#endif
