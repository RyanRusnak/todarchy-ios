#if !os(macOS)
import SwiftUI

struct IPadRootView: View {
    @EnvironmentObject var store: TaskStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCapture = false
    @State private var showSettings = false
    @State private var captureText = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IPadSidebar(onOpenSettings: { showSettings = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            IPadMainView(onCaptureRequest: { showCapture = true })
                .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        } detail: {
            IPadInspector()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.bg)
        .sheet(isPresented: $showCapture) {
            IPadCaptureSheet(text: $captureText, onCommit: {
                store.add(raw: captureText)
                captureText = ""
                showCapture = false
            }, onCancel: { showCapture = false })
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            IOSSettingsSheet(
                persistence: TaskStorePersistence.shared,
                onClose: { showSettings = false }
            )
        }
    }
}

// MARK: - Sidebar

private struct IPadSidebar: View {
    @EnvironmentObject var store: TaskStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("todarchy")
                    .font(Typo.mono(18, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("~/tasks · matt")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)

            sectionHeader("LISTS")

            ForEach(store.allLists) { list in
                listRow(list)
            }

            sectionHeader("CONTEXTS").padding(.top, 18)

            ForEach(TaskContext.allCases) { ctx in
                contextRow(ctx)
            }

            Spacer()

            settingsButton
            hotkeyHints()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.bgElev)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gear").foregroundStyle(Theme.fgMute)
                Text("Settings")
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fgDim)
                Spacer()
                if SyncSettings.shared.mode.kind != .localOnly {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Typo.mono(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.fgMute)
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
    }

    private func listRow(_ list: ProjectItem) -> some View {
        let active: Bool = {
            guard store.activeContextFilter == nil else { return false }
            if case .list(let id) = store.activeSelection { return id == list.id }
            return false
        }()
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(active ? list.accent : .clear)
                .frame(width: 3, height: 22)

            Image(systemName: list.icon)
                .foregroundStyle(list.accent)
                .frame(width: 18)

            Text(list.name)
                .font(Typo.mono(14, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.fg : Theme.fgDim)

            if list.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(list.accent.opacity(0.8))
                    .accessibilityLabel("Shared project")
            }

            Spacer()

            Text("\(store.countOpen(in: list.id))")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Rectangle()
                .fill(active ? list.accent.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.activeSelection = .list(list.id)
            store.activeContextFilter = nil
        }
    }

    private func contextRow(_ ctx: TaskContext) -> some View {
        let active = store.activeContextFilter == ctx
        let count = store.countOpen(ctx: ctx)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(active ? ctx.color : .clear)
                .frame(width: 3, height: 22)
            RoundedRectangle(cornerRadius: 2)
                .fill(ctx.color)
                .frame(width: 8, height: 8)
            Text(ctx.rawValue)
                .font(Typo.mono(13))
                .foregroundStyle(active ? ctx.color : Theme.fgDim)
            Spacer()
            Text("\(count)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 6)
        .background(
            Rectangle().fill(active ? ctx.color.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if active {
                store.activeContextFilter = nil
            } else {
                store.activeContextFilter = ctx
            }
        }
    }

    private func hotkeyHints() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOTKEYS")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.bottom, 4)
            hint("j k", "move")
            hint("x", "complete")
            hint("⌘N", "new task")
            hint("⌘K", "palette")
            hint("⌘F", "search")
            hint("i", "toggle inspector")
            hint("?", "all keys")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func hint(_ k: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(k)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.bgSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(desc)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Spacer()
        }
    }
}

// MARK: - Main view

private struct IPadMainView: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject private var sync = SyncSettings.shared
    let onCaptureRequest: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider().background(Theme.border)
            toolbar()
            Divider().background(Theme.border)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.viewTasks) { task in
                        TaskRow(
                            task: task,
                            listMeta: store.project(id: task.list),
                            showList: store.activeContextFilter != nil,
                            highlightedCtx: store.activeContextFilter,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.toggleDone(task.id)
                                }
                            },
                            onTapCtx: { c in
                                store.activeContextFilter = (store.activeContextFilter == c) ? nil : c
                            }
                        )
                        .background(task.id == store.selectedTaskId ? Theme.panel : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedTaskId = task.id }
                    }
                    Text("── end of \(endLabel) ──")
                        .font(Typo.mono(11))
                        .tracking(0.5)
                        .foregroundStyle(Theme.fgFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            }
            .refreshable {
                SyncSettings.shared.beginSync()
                let result = await Task.detached { TaskStorePersistence.shared.syncNow() }.value
                await MainActor.run { SyncSettings.shared.endSync(result: result) }
            }

            footer()
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            Button(action: onCaptureRequest) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("capture").font(Typo.mono(13, weight: .semibold))
                }
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
                .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(24)
        }
    }

    private func header() -> some View {
        HStack(spacing: 8) {
            if let ctx = store.activeContextFilter {
                Text("~/ctx/").font(Typo.mono(15)).foregroundStyle(Theme.fgMute)
                Text(ctx.rawValue).font(Typo.mono(18, weight: .semibold)).foregroundStyle(ctx.color)
                Text("· \(store.countOpen(ctx: ctx))").font(Typo.mono(13)).foregroundStyle(Theme.fgFaint)
                Spacer()
                Button("clear") { store.activeContextFilter = nil }
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
            } else if case .list(let id) = store.activeSelection, let list = store.project(id: id) {
                Text("~/tasks/").font(Typo.mono(15)).foregroundStyle(Theme.fgMute)
                Text(list.name).font(Typo.mono(18, weight: .semibold)).foregroundStyle(list.accent)
                Text("· \(store.countOpen(in: id))").font(Typo.mono(13)).foregroundStyle(Theme.fgFaint)
                Spacer()
                Text("updated just now")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.success)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func toolbar() -> some View {
        HStack(spacing: 14) {
            Text("sort").font(Typo.mono(11)).foregroundStyle(Theme.fgMute)
            Text("created ↓").font(Typo.mono(11, weight: .semibold)).foregroundStyle(Theme.fg)
            Divider().frame(height: 14).background(Theme.border)
            Text("show").font(Typo.mono(11)).foregroundStyle(Theme.fgMute)
            pill("todo", active: !store.showDone) { store.showDone = false }
            pill("deferred", active: store.showDeferred) { store.showDeferred.toggle() }
            pill("done", active: store.showDone) { store.showDone.toggle() }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.fgMute)
                Text("search")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                Text("⌘F")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.bgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func pill(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typo.mono(11, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.fgMute)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(active ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func footer() -> some View {
        HStack(spacing: 14) {
            Text("\(store.viewTasks.count) tasks")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Text("· press ⌘N to capture")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
            Spacer()
            Text("NORMAL")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.accent)
            Text("·").foregroundStyle(Theme.border)
            ipadSyncIndicator
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var ipadSyncIndicator: some View {
        if sync.mode.kind == .localOnly {
            Circle().fill(Theme.fgFaint).frame(width: 5, height: 5)
            Text("local only").font(Typo.mono(10)).foregroundStyle(Theme.fgMute)
        } else if sync.isSyncing {
            Text("syncing").font(Typo.mono(10)).foregroundStyle(Theme.accent)
        } else if sync.lastSyncError != nil {
            Circle().fill(Theme.danger).frame(width: 5, height: 5)
            Text("sync failed").font(Typo.mono(10)).foregroundStyle(Theme.danger)
        } else {
            Circle().fill(Theme.success).frame(width: 5, height: 5)
            Text("synced").font(Typo.mono(10)).foregroundStyle(Theme.success)
        }
    }

    private var endLabel: String {
        if let ctx = store.activeContextFilter { return ctx.rawValue }
        if case .list(let id) = store.activeSelection { return store.project(id: id)?.name ?? id }
        return ""
    }
}

// MARK: - Inspector

private struct IPadInspector: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        Group {
            if let id = store.selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
                TaskInspectorContent(task: task)
            } else {
                emptyInspector
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgElev)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var emptyInspector: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(Theme.fgFaint)
            Text("no task selected")
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fgMute)
            Text("tap a row to inspect")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Capture sheet

private struct IPadCaptureSheet: View {
    @EnvironmentObject var store: TaskStore
    @Binding var text: String
    @FocusState private var focus: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("new task →").font(Typo.mono(12)).foregroundStyle(Theme.fgMute)
                if case .list(let id) = store.activeSelection, let l = store.project(id: id) {
                    Text("~/tasks/\(l.name)")
                        .font(Typo.mono(12, weight: .semibold))
                        .foregroundStyle(l.accent)
                }
                Spacer()
                Button("esc") { onCancel() }
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
            }

            HStack(alignment: .top) {
                Text("+").font(Typo.mono(22)).foregroundStyle(Theme.accent)
                TextField(text: $text, axis: .vertical) {
                    Text("call mom @phone !today").foregroundStyle(Theme.fgMute)
                }
                .font(Typo.mono(16))
                .foregroundStyle(Theme.fg)
                .focused($focus)
                .onSubmit(onCommit)
            }

            let parsed = QuickAddParser.parse(text)
            HStack(spacing: 8) {
                if !parsed.title.isEmpty {
                    Text(parsed.title).font(Typo.mono(13)).foregroundStyle(Theme.fg)
                    if let c = parsed.ctx { CtxChip(ctx: c, highlighted: true) }
                    if let d = parsed.due { DueChip(due: d) }
                    if !parsed.note.isEmpty {
                        Text("/ \(parsed.note)").font(Typo.mono(11)).foregroundStyle(Theme.fgFaint)
                    }
                } else {
                    Text("preview appears as you type…")
                        .font(Typo.mono(12))
                        .italic()
                        .foregroundStyle(Theme.fgFaint)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TaskContext.allCases) { c in
                        tokenButton(c.rawValue, color: c.color) { append(c.rawValue) }
                    }
                    tokenButton("!today", color: Theme.danger) { append("!today") }
                    tokenButton("!tomorrow", color: Theme.warn) { append("!tomorrow") }
                    tokenButton("!week", color: Theme.blue) { append("!week") }
                    tokenButton("/ note", color: Theme.fgMute) { append("/") }
                }
            }

            HStack {
                Spacer()
                Button("save →") { onCommit() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(13, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(parsed.title.isEmpty)
                    .opacity(parsed.title.isEmpty ? 0.5 : 1)
            }
        }
        .padding(24)
        .background(Theme.bgElev)
        .onAppear { focus = true }
    }

    private func append(_ tok: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        text = t.isEmpty ? tok + " " : t + " " + tok + " "
        focus = true
    }

    private func tokenButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typo.mono(12.5))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
#endif
