import SwiftUI

/// A row representing a single task. Used by iOS, iPad, and macOS lists.
struct TaskRow: View {
    let task: TaskItem
    let listMeta: ProjectItem?
    let showList: Bool
    var highlightedCtx: TaskContext? = nil
    var compact: Bool = false
    var isEditing: Bool = false

    var onToggle: () -> Void = {}
    var onTapCtx: (TaskContext) -> Void = { _ in }
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editBuffer: String = ""
    @FocusState private var editFocus: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Checkbox(done: task.isDone, deferred: task.isDeferred)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    let tf = TextField("", text: $editBuffer)
                        .textFieldStyle(.plain)
                        .font(Typo.mono(compact ? 14 : 15, weight: .medium))
                        .foregroundStyle(Theme.fg)
                        .focused($editFocus)
                        .onSubmit {
                            onCommitEdit(editBuffer)
                        }
                        .onAppear {
                            editBuffer = task.title
                            editFocus = true
                        }
                    #if os(macOS)
                    tf.onExitCommand { onCancelEdit() }
                    #else
                    tf
                    #endif
                } else {
                    Text(task.title)
                        .font(Typo.mono(compact ? 14 : 15, weight: .medium))
                        .foregroundStyle(task.isDone ? Theme.fgMute : Theme.fg)
                        .strikethrough(task.isDone, color: Theme.fgFaint)
                        .lineLimit(compact ? 1 : 2)
                }

                if !task.note.isEmpty {
                    HStack(spacing: 4) {
                        Text("└").foregroundStyle(Theme.fgFaint)
                        Text(task.note.split(separator: "\n").first.map(String.init) ?? "")
                            .lineLimit(1)
                    }
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgMute)
                }

                HStack(spacing: 10) {
                    if let ctx = task.ctx {
                        Button(action: { onTapCtx(ctx) }) {
                            CtxChip(ctx: ctx, highlighted: ctx == highlightedCtx)
                        }
                        .buttonStyle(.plain)
                    }

                    if showList, let l = listMeta {
                        HStack(spacing: 5) {
                            ListDot(color: l.accent, size: 5)
                            Text(l.name).font(Typo.mono(11))
                        }
                        .foregroundStyle(Theme.fgMute)
                    }

                    if let due = task.due {
                        DueChip(due: due)
                    }

                    if task.isDeferred, let d = task.deferUntil {
                        DeferChip(date: d)
                    }

                    Spacer(minLength: 0)

                    Text(TimeAgo.short(task.created))
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.fgFaint)
                }
            }
        }
        .padding(.vertical, compact ? 10 : 14)
        .padding(.horizontal, 16)
        .frame(minHeight: compact ? 48 : 64, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(task.isDone ? 0.55 : 1.0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
        }
    }
}
