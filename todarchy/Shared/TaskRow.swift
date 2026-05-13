import SwiftUI

/// A row representing a single task. Used by iOS, iPad, and macOS lists.
struct TaskRow: View {
    let task: TaskItem
    let listMeta: ProjectItem?
    let showList: Bool
    var highlightedCtx: TaskContext? = nil
    var compact: Bool = false
    var isEditing: Bool = false
    /// When true on macOS, this row picks up keyboard-driven completion
    /// (`.todarchyToggleDone`) and runs the same `handleToggle` flow that
    /// a checkbox click does — so space / x / ⌘K → Complete all animate
    /// with the filled circle, pulse, and strikethrough.
    var isSelected: Bool = false

    var onToggle: () -> Void = {}
    var onTapCtx: (TaskContext) -> Void = { _ in }
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editBuffer: String = ""
    @FocusState private var editFocus: Bool

    /// True between the click on the checkbox and the actual `onToggle`
    /// commit. Lets the row paint itself in the done state (filled circle,
    /// strikethrough, dimmed text) for ~half a beat so the user sees the
    /// completion register before the row vanishes from filtered lists.
    @State private var pendingComplete: Bool = false

    /// Bounces the checkbox once when the user marks the task done.
    @State private var completionPulse: Bool = false

    private var displayDone: Bool { task.isDone || pendingComplete }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The macOS row sits inside a parent that takes single-tap +
            // double-tap recognizers; without an explicit hit shape on the
            // button label, those parent gestures can swallow circle clicks
            // and `handleToggle` never runs (so no fill animation either).
            // The frame + contentShape match the popover row.
            Button(action: handleToggle) {
                Checkbox(done: displayDone, deferred: task.isDeferred)
                    .scaleEffect(completionPulse ? 1.18 : 1.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.55),
                               value: completionPulse)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
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
                        .foregroundStyle(displayDone ? Theme.fgMute : Theme.fg)
                        .strikethrough(displayDone, color: Theme.fgFaint)
                        .lineLimit(compact ? 1 : 2)
                        .animation(.easeOut(duration: 0.2), value: displayDone)
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
        .opacity(displayDone ? 0.55 : 1.0)
        .animation(.easeOut(duration: 0.2), value: displayDone)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
        }
        .onSelectedToggleDone(isSelected: isSelected, action: handleToggle)
    }

    private func handleToggle() {
        // Re-toggling an already-done task (un-completing) commits
        // immediately — no need to animate the "going back to open"
        // transition since the row stays visible either way.
        if task.isDone {
            onToggle()
            return
        }
        // Already mid-animation: ignore extra clicks so we don't
        // double-fire onToggle.
        if pendingComplete { return }

        pendingComplete = true
        completionPulse = true

        // Drop the pulse just after it peaks so the spring settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            completionPulse = false
        }
        // Commit the store mutation after the user has had time to see
        // the circle fill + checkmark land. Tuned to feel snappy, not
        // sluggish — rows still vanish quickly from filtered lists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            onToggle()
            pendingComplete = false
        }
    }
}

private extension View {
    /// Wires the row up to macOS's keyboard-driven Toggle Complete
    /// (`x`, space, ⌘K → Complete) so the selected row runs the same
    /// `handleToggle` animation a checkbox click does. No-op elsewhere.
    @ViewBuilder
    func onSelectedToggleDone(isSelected: Bool, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onReceive(NotificationCenter.default.publisher(for: .todarchyToggleDone)) { _ in
            if isSelected { action() }
        }
        #else
        self
        #endif
    }
}
