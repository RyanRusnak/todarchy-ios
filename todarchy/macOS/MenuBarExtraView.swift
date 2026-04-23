#if os(macOS)
import SwiftUI
import AppKit

/// Popover content for the menu bar extra. Shows today's tasks + quick add.
struct MenuBarExtraView: View {
    @EnvironmentObject var store: TaskStore
    @State private var quickAdd: String = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)
            todayList
            Divider().background(Theme.border)
            quickAddBar
        }
        .frame(width: 360)
        .background(Theme.bgElev)
        .onAppear { focus = true }
    }

    private var header: some View {
        HStack {
            Text("todarchy")
                .font(Typo.mono(13, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("today")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Spacer()
            Text("\(todayCount) open")
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
            .help("Open todarchy")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var todayList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if todayTasks.isEmpty {
                    VStack(spacing: 4) {
                        Text("nothing due today")
                            .font(Typo.mono(12))
                            .foregroundStyle(Theme.fgMute)
                        Text("add one below")
                            .font(Typo.mono(10))
                            .foregroundStyle(Theme.fgFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(todayTasks) { task in
                        todayRow(task)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func todayRow(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            Button {
                store.toggleDone(task.id)
            } label: {
                Checkbox(done: task.isDone, size: 16)
            }
            .buttonStyle(.plain)

            Text(task.title)
                .font(Typo.mono(12))
                .foregroundStyle(task.isDone ? Theme.fgMute : Theme.fg)
                .strikethrough(task.isDone, color: Theme.fgFaint)
                .lineLimit(1)

            Spacer()

            if let ctx = task.ctx {
                Text(ctx.rawValue)
                    .font(Typo.mono(10, weight: .semibold))
                    .foregroundStyle(ctx.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.selectedTaskId = task.id
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var quickAddBar: some View {
        HStack(spacing: 8) {
            Text("+")
                .font(Typo.mono(16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            TextField("add task to inbox", text: $quickAdd)
                .textFieldStyle(.plain)
                .font(Typo.mono(13))
                .focused($focus)
                .onSubmit {
                    let trimmed = quickAdd.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    // Preserve the user's current scope: add goes to whatever
                    // list was active. If the menu bar is the first surface
                    // opened this session, that'll be inbox.
                    store.add(raw: trimmed)
                    quickAdd = ""
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var todayTasks: [TaskItem] {
        store.tasks
            .filter { !$0.isDone && !$0.isDeferred && $0.due == .today }
    }

    private var todayCount: Int { todayTasks.count }
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
