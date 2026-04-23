import SwiftUI

/// Inspector panel content — used by both iPad (detail column) and macOS (inspector pane).
struct TaskInspectorContent: View {
    @EnvironmentObject var store: TaskStore
    let task: TaskItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(task.isDone ? "COMPLETED" : (task.isDeferred ? "DEFERRED" : "SELECTED"))
                        .font(Typo.mono(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(task.isDone ? Theme.success : (task.isDeferred ? Theme.purple : Theme.fgMute))
                    Spacer()
                    Text("⌥↵").font(Typo.mono(10)).foregroundStyle(Theme.fgFaint)
                }

                Text(task.title)
                    .font(Typo.mono(18, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .strikethrough(task.isDone, color: Theme.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)

                metaGrid

                if !task.note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTE")
                            .font(Typo.mono(10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.fgMute)
                        Text(task.note)
                            .font(Typo.mono(12))
                            .foregroundStyle(Theme.fgDim)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bgSoft)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                VStack(spacing: 8) {
                    Button {
                        store.toggleDone(task.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text(task.isDone ? "undo" : "complete")
                                .font(Typo.mono(13, weight: .semibold))
                            Spacer()
                            Text("x")
                                .font(Typo.mono(11))
                                .foregroundStyle(Theme.success.opacity(0.7))
                        }
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Theme.success.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.success.opacity(0.3), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Button {
                            store.defer_(task.id, until: Date().addingTimeInterval(24 * 3600))
                        } label: {
                            Text("defer")
                                .font(Typo.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.purple)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.purple.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Menu {
                            ForEach(store.allLists.filter { $0.id != task.list }) { l in
                                Button(l.name) { store.move(task.id, toList: l.id) }
                            }
                        } label: {
                            Text("move")
                                .font(Typo.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.fgDim)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.bgSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var metaGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("list") {
                if let l = store.project(id: task.list) {
                    HStack(spacing: 6) {
                        ListDot(color: l.accent)
                        Text(l.name).foregroundStyle(Theme.fg)
                    }
                    .font(Typo.mono(12))
                }
            }
            metaRow("context") {
                if let c = task.ctx {
                    CtxChip(ctx: c, highlighted: true)
                } else {
                    Text("—").font(Typo.mono(12)).foregroundStyle(Theme.fgMute)
                }
            }
            metaRow("due") {
                if let d = task.due { DueChip(due: d) }
                else { Text("—").font(Typo.mono(12)).foregroundStyle(Theme.fgMute) }
            }
            if let d = task.deferUntil, d > Date() {
                metaRow("deferred") {
                    DeferChip(date: d)
                }
            }
            metaRow("created") {
                Text(TimeAgo.short(task.created) + " ago")
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
            }
            metaRow("id") {
                Text(String(task.id.prefix(8)))
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgFaint)
            }
        }
    }

    @ViewBuilder
    private func metaRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
                .frame(width: 70, alignment: .leading)
            content()
            Spacer()
        }
    }
}
