#if os(macOS)
import SwiftUI
import AppKit

/// Popover content for the menu bar extra. Shows today's tasks, the
/// inbox (for fresh captures the user hasn't triaged yet), and a
/// quick-add bar that drops new tasks into the inbox.
struct MenuBarExtraView: View {
    @EnvironmentObject var store: TaskStore
    @State private var quickAdd: String = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)
            list
            Divider().background(Theme.border)
            quickAddBar
        }
        .frame(width: 360)
        .background(Theme.bgElev)
        .onAppear { focus = true }
    }

    private var header: some View {
        HStack {
            Text("todokase")
                .font(Typo.mono(13, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("today + inbox")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Spacer()
            Text("\(todayTasks.count) today · \(inboxTasks.count) inbox")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Open todokase")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if todayTasks.isEmpty && inboxTasks.isEmpty {
                    emptyState
                } else {
                    if !todayTasks.isEmpty {
                        sectionHeader("today")
                        ForEach(todayTasks) { task in
                            MenuBarTaskRow(task: task)
                                .transition(.removalCollapse)
                        }
                    }
                    if !inboxTasks.isEmpty {
                        sectionHeader("inbox")
                        ForEach(inboxTasks) { task in
                            MenuBarTaskRow(task: task)
                                .transition(.removalCollapse)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22),
                       value: todayTasks.map(\.id) + inboxTasks.map(\.id))
        }
        .frame(maxHeight: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("inbox zero, nothing due today")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgMute)
            Text("add one below")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(Typo.mono(10, weight: .semibold))
            .foregroundStyle(Theme.fgMute)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickAddBar: some View {
        HStack(spacing: 8) {
            Text("+")
                .font(Typo.mono(16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            TextField("add task to inbox", text: $quickAdd)
                .textFieldStyle(.plain)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fg)
                .tint(Theme.accent)
                .focused($focus)
                .onSubmit(submitQuickAdd)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func submitQuickAdd() {
        let trimmed = quickAdd.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Always route menu bar captures to the inbox so they don't get
        // dropped into whichever project the main window happens to be on.
        store.add(raw: trimmed, list: "inbox")
        quickAdd = ""
    }

    private var todayTasks: [TaskItem] {
        store.tasks
            .filter { !$0.isDone && !$0.isDeferred && $0.due == .today }
    }

    /// Open inbox tasks that aren't already shown in `todayTasks`. The
    /// `due != .today` filter dedupes inbox items the user has explicitly
    /// scheduled for today — they belong in the today section, not both.
    private var inboxTasks: [TaskItem] {
        store.tasks.filter {
            $0.list == "inbox"
                && !$0.isDone
                && !$0.isDeferred
                && $0.due != .today
        }
    }
}

/// Single row inside the menu-bar popover. Owns its own `pendingComplete`
/// state so clicking the circle plays a fill + checkmark + strikethrough
/// animation before the row is removed by the parent's filter.
private struct MenuBarTaskRow: View {
    @EnvironmentObject var store: TaskStore
    let task: TaskItem

    @State private var pendingComplete: Bool = false
    @State private var completionPulse: Bool = false

    private var displayDone: Bool { task.isDone || pendingComplete }

    var body: some View {
        HStack(spacing: 8) {
            // Wrap the 16pt checkbox in a 28pt hit area so the click target
            // is comfortable and so SwiftUI doesn't lose the tap to the
            // row-level double-tap recognizer below.
            Button(action: handleToggle) {
                Checkbox(done: displayDone, size: 16)
                    .scaleEffect(completionPulse ? 1.18 : 1.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.55),
                               value: completionPulse)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(displayDone ? "Mark not done" : "Mark done")

            Text(task.title)
                .font(Typo.mono(12))
                .foregroundStyle(displayDone ? Theme.fgMute : Theme.fg)
                .strikethrough(displayDone, color: Theme.fgFaint)
                .lineLimit(1)
                .animation(.easeOut(duration: 0.2), value: displayDone)

            Spacer()

            if let ctx = task.ctx {
                Text(ctx.rawValue)
                    .font(Typo.mono(10, weight: .semibold))
                    .foregroundStyle(ctx.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .opacity(displayDone ? 0.6 : 1.0)
        .animation(.easeOut(duration: 0.2), value: displayDone)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.selectedTaskId = task.id
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleToggle() {
        if task.isDone {
            store.toggleDone(task.id)
            return
        }
        if pendingComplete { return }

        pendingComplete = true
        completionPulse = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            completionPulse = false
        }
        // Holds the row visible just long enough for the user to register
        // the fill + checkmark + strikethrough before the popover's filter
        // drops it. Keep this in sync with TaskRow.handleToggle so the two
        // surfaces feel identical.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            store.toggleDone(task.id)
            pendingComplete = false
        }
    }
}

private extension AnyTransition {
    /// Removal collapses the row's height while fading + sliding upward,
    /// so when a completed task drops out of the filter the rows below
    /// glide up rather than snap.
    static var removalCollapse: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .move(edge: .leading)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.95, anchor: .leading))
        )
    }
}

/// Menu-bar badge label: short icon + today's open count.
struct MenuBarBadge: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        let n = store.tasks.filter {
            !$0.isDone && !$0.isDeferred && $0.due == .today
        }.count
        HStack(spacing: 4) {
            Image(systemName: "checkmark.square")
            if n > 0 { Text("\(n)") }
        }
    }
}
#endif
