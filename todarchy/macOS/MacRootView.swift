#if os(macOS)
import SwiftUI
import AppKit

struct MacRootView: View {
    @EnvironmentObject var store: TaskStore
    @State private var vimMode: VimMode = .normal
    @State private var showInspector: Bool = true
    @State private var showPalette = false
    @State private var showCapture = false
    @State private var showSearch = false
    @State private var showProjectEditor = false
    @State private var showVoiceCapture = false
    @State private var deferTarget: DeferTarget?
    @State private var captureText = ""
    @StateObject private var keyMonitor = MacMainKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                MacSidebar()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
            } detail: {
                MacMainView(onOpenCapture: { showCapture = true })
                    .inspector(isPresented: $showInspector) {
                        MacInspector()
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                    }
            }
            .navigationSplitViewStyle(.balanced)

            MacStatusBar(vimMode: vimMode)
        }
        .background(Theme.bg)
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: $showPalette) {
            CommandPalette(onClose: { showPalette = false })
                .frame(width: 620, height: 420)
        }
        .sheet(isPresented: $showCapture) {
            MacCaptureWindow(text: $captureText,
                             onCommit: { stayOpen in
                                 store.add(raw: captureText)
                                 captureText = ""
                                 if !stayOpen { showCapture = false }
                                 // stayOpen = true keeps the sheet
                                 // up; the TextField stays focused
                                 // because `focus = true` is set on
                                 // .onAppear and SwiftUI doesn't
                                 // re-init the view here.
                             },
                             onCancel: { showCapture = false })
            .frame(width: 560)
        }
        .sheet(isPresented: $showSearch) {
            TaskSearchSheet(onClose: { showSearch = false })
                .frame(width: 620, height: 420)
        }
        .sheet(item: $deferTarget) { target in
            DeferPickerSheet(taskId: target.id,
                             onClose: { deferTarget = nil })
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 500)
        }
        .sheet(isPresented: $showProjectEditor) {
            ProjectEditorSheet(onClose: { showProjectEditor = false })
                .frame(width: 560, height: 420)
        }
        .sheet(isPresented: $showVoiceCapture) {
            VoiceCaptureSheet(onClose: { showVoiceCapture = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenPalette)) { _ in
            showPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenCapture)) { _ in
            showCapture = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyToggleInspector)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                showInspector.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyUndo)) { _ in
            store.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenSearch)) { _ in
            showSearch = true
        }
        // Toggle Complete is now consumed by the selected `TaskRow`'s
        // own listener so the keyboard path animates exactly like a
        // checkbox click. See `TaskRow.onSelectedToggleDone`.
        .onReceive(NotificationCenter.default.publisher(for: .todarchyDeleteSelected)) { _ in
            store.deleteSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyDeferSelected)) { _ in
            store.deferSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenDeferPicker)) { _ in
            guard let sid = store.selectedTaskId else { return }
            deferTarget = DeferTarget(id: sid)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenProjectEditor)) { _ in
            showProjectEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchySyncNow)) { _ in
            Task.detached {
                await MainActor.run { SyncSettings.shared.beginSync() }
                let result = TaskStorePersistence.shared.syncNow()
                await MainActor.run { SyncSettings.shared.endSync(result: result) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todarchyOpenVoiceCapture)) { _ in
            showVoiceCapture = true
        }
        .onAppear {
            keyMonitor.store = store
            keyMonitor.install()
            if store.selectedTaskId == nil {
                store.selectFirst()
            }
        }
        .onDisappear {
            keyMonitor.uninstall()
        }
        .onChange(of: showPalette) { _, v in keyMonitor.paletteShowing = v }
        .onChange(of: showCapture) { _, v in keyMonitor.captureShowing = v }
        .onChange(of: showSearch) { _, v in keyMonitor.searchShowing = v }
    }
}

enum VimMode: String {
    case normal = "NORMAL"
    case insert = "INSERT"
    case search = "SEARCH"
    case cmd    = "CMD"
    case defer_ = "DEFER"

    var color: Color {
        switch self {
        case .normal: return Theme.accent
        case .insert: return Theme.success
        case .search: return Theme.warn
        case .cmd:    return Theme.purple
        case .defer_: return Theme.cyan
        }
    }
}

// MARK: - Sidebar

private struct MacSidebar: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject private var syncSettings = SyncSettings.shared
    @State private var showContextEditor: Bool = false
    /// Drives the destructive confirmation alert when the user picks
    /// "Delete project" or "Leave shared project" from a row's
    /// context menu. Nil = no alert showing.
    @State private var pendingDelete: ProjectItem?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("todarchy")
                    .font(Typo.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("~/tasks")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 18)

            // Inbox row
            listRow(store.inboxProject, kbd: "0")

            sectionHeader("PROJECTS").padding(.top, 16)
            ForEach(Array(store.projects.enumerated()), id: \.element.id) { idx, project in
                listRow(project, kbd: "\(idx + 1)")
            }

            contextsHeader.padding(.top, 18)
            ForEach(store.contexts) { ctx in
                contextRow(ctx)
            }

            Spacer()

            hintBlock()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgElev)
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showContextEditor) {
            ContextEditorSheet()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
        .alert(
            pendingDelete?.isShared == true ? "Leave shared project?" : "Delete project?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button(project.isShared ? "Leave" : "Delete", role: .destructive) {
                performDestructive(on: project)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { project in
            Text(deleteAlertMessage(for: project))
        }
        .alert(
            "Couldn't leave shared project",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private func performDestructive(on project: ProjectItem) {
        if project.isShared {
            guard let manager = syncSettings.sharedProjectManager else {
                deleteError = "Sync isn't set up — can't leave a shared project."
                return
            }
            do {
                try store.leaveSharedProject(project.id, manager: manager)
            } catch let err as TaskStore.ShareError {
                deleteError = err.errorDescription ?? "Couldn't leave shared project."
            } catch {
                deleteError = error.localizedDescription
            }
        } else {
            store.deleteProject(id: project.id)
        }
    }

    private func deleteAlertMessage(for project: ProjectItem) -> String {
        if project.isShared {
            return "Remove \"\(project.name)\" from this device. It'll stay available for anyone you shared it with."
        }
        let count = store.countOpen(in: project.id)
        if count == 0 {
            return "Remove \"\(project.name)\". This can be undone with ⌘Z."
        }
        return "Remove \"\(project.name)\" and its \(count) open task\(count == 1 ? "" : "s"). This can be undone with ⌘Z."
    }

    private var contextsHeader: some View {
        HStack {
            sectionHeader("CONTEXTS")
            Spacer()
            Button {
                showContextEditor = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit contexts")
            .padding(.trailing, 12)
        }
        .padding(.bottom, -4)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Typo.mono(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.fgMute)
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
    }

    private func listRow(_ list: ProjectItem, kbd: String) -> some View {
        let active: Bool = {
            guard store.activeContextFilter == nil else { return false }
            if case .list(let id) = store.activeSelection { return id == list.id }
            return false
        }()
        return HStack(spacing: 8) {
            Image(systemName: list.icon)
                .foregroundStyle(list.accent)
                .frame(width: 14)
            Text(list.name)
                .font(Typo.mono(13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.fg : Theme.fgDim)
            if list.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(list.accent.opacity(0.8))
                    .help("Shared project")
            }
            Spacer()
            Text("\(store.countOpen(in: list.id))")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
            Text(kbd)
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            Rectangle().fill(active ? list.accent.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.activeSelection = .list(list.id)
            store.activeContextFilter = nil
        }
        .contextMenu {
            if list.isInbox {
                // Inbox isn't deletable / shareable. Empty menu so
                // a right-click doesn't suggest actions that won't work.
            } else if list.isShared {
                Button(role: .destructive) {
                    pendingDelete = list
                } label: {
                    Label("Leave shared project", systemImage: "person.crop.circle.badge.xmark")
                }
            } else {
                Button(role: .destructive) {
                    pendingDelete = list
                } label: {
                    Label("Delete project", systemImage: "trash")
                }
            }
        }
    }

    private func contextRow(_ ctx: TaskContext) -> some View {
        let active = store.activeContextFilter == ctx
        let count = store.countOpen(ctx: ctx)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ctx.color)
                .frame(width: 7, height: 7)
            Text(ctx.rawValue)
                .font(Typo.mono(12))
                .foregroundStyle(active ? ctx.color : Theme.fgDim)
            Spacer()
            Text("\(count)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(
            Rectangle().fill(active ? ctx.color.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.activeContextFilter = (active) ? nil : ctx
        }
    }

    private func hintBlock() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            hint("j k", "move")
            hint("J K", "reorder")
            hint("← →", "switch list")
            hint("x ␣", "complete")
            hint("o", "new")
            hint("e", "edit")
            hint("⇥", "indent")
            hint("z", "collapse")
            hint("u", "undo")
            hint("dd", "delete")
            hint("s", "defer")
            hint("i", "inspector")
            hint("/", "search")
            hint(":", "command")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 14)
        }
    }

    private func hint(_ k: String, _ desc: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.bgSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1)
                )
            Text(desc).font(Typo.mono(10)).foregroundStyle(Theme.fgMute)
            Spacer()
        }
    }
}

// MARK: - Main view

private struct MacMainView: View {
    @EnvironmentObject var store: TaskStore
    let onOpenCapture: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider().background(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.viewTree) { row in
                            HStack(spacing: 0) {
                                if row.depth > 0 {
                                    Spacer().frame(width: CGFloat(row.depth) * 18)
                                }
                                disclosure(for: row)
                                TaskRow(
                                    task: row.task,
                                    listMeta: store.project(id: row.task.list),
                                    showList: store.activeContextFilter != nil,
                                    highlightedCtx: store.activeContextFilter,
                                    isEditing: store.editingTaskId == row.task.id,
                                    isSelected: row.task.id == store.selectedTaskId,
                                    onToggle: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            store.toggleDone(row.task.id)
                                        }
                                    },
                                    onTapCtx: { c in
                                        store.activeContextFilter = (store.activeContextFilter == c) ? nil : c
                                    },
                                    onCommitEdit: { newTitle in
                                        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                                        if !trimmed.isEmpty {
                                            store.setTitle(row.task.id, title: trimmed)
                                        }
                                        store.editingTaskId = nil
                                    },
                                    onCancelEdit: {
                                        store.editingTaskId = nil
                                    }
                                )
                            }
                            .background(row.task.id == store.selectedTaskId ? Theme.panel : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                store.selectedTaskId = row.task.id
                                store.editingTaskId = row.task.id
                            }
                            .onTapGesture { store.selectedTaskId = row.task.id }
                            .contextMenu { rowMenu(for: row.task) }
                            .id(row.task.id)
                        }
                        Text("── end of \(endLabel) ──")
                            .font(Typo.mono(11))
                            .tracking(0.5)
                            .foregroundStyle(Theme.fgFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                }
                .onChange(of: store.selectedTaskId) { _, newId in
                    guard let newId else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
                .onChange(of: store.tasks) { _, _ in
                    // Keep the selected task on-screen after reorder.
                    guard let id = store.selectedTaskId else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private func rowMenu(for task: TaskItem) -> some View {
        Button(task.isDone ? "Mark Incomplete" : "Mark Complete") {
            store.toggleDone(task.id)
        }
        Button("Edit") {
            store.selectedTaskId = task.id
            store.editingTaskId = task.id
        }
        Divider()
        Button("Defer…") {
            store.selectedTaskId = task.id
            NotificationCenter.default.post(name: .todarchyOpenDeferPicker, object: nil)
        }
        if task.deferUntil != nil {
            Button("Clear Defer") { store.clearDefer(task.id) }
        }
        Divider()
        Menu("Move to") {
            ForEach(store.allLists.filter { $0.id != task.list }) { l in
                Button(l.name) { store.move(task.id, toList: l.id) }
            }
        }
        Menu("Context") {
            Button("None") { store.setContext(task.id, ctx: nil) }
            ForEach(store.contexts) { c in
                Button(c.rawValue) { store.setContext(task.id, ctx: c) }
            }
        }
        Menu("Due") {
            Button("None") { store.setDue(task.id, due: nil) }
            ForEach(DueBucket.allCases) { d in
                Button(d.label) { store.setDue(task.id, due: d) }
            }
        }
        Divider()
        Button("Indent") { store.selectedTaskId = task.id; store.indentSelected() }
        Button("Outdent") { store.selectedTaskId = task.id; store.outdentSelected() }
        Divider()
        Button("Delete", role: .destructive) {
            store.selectedTaskId = task.id
            store.deleteSelected()
        }
    }

    @ViewBuilder
    private func disclosure(for row: TaskTreeRow) -> some View {
        if row.hasChildren {
            Button {
                store.selectedTaskId = row.task.id
                _ = store.toggleCollapseSelected()
            } label: {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.fgMute)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        } else {
            Spacer().frame(width: 14)
        }
    }

    private func header() -> some View {
        HStack(spacing: 10) {
            if let ctx = store.activeContextFilter {
                Text("~/ctx/").font(Typo.mono(14)).foregroundStyle(Theme.fgMute)
                Text(ctx.rawValue).font(Typo.mono(18, weight: .semibold)).foregroundStyle(ctx.color)
                Text("· \(store.countOpen(ctx: ctx))").font(Typo.mono(12)).foregroundStyle(Theme.fgFaint)
                Spacer()
                Button("clear") { store.activeContextFilter = nil }
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1)
                    )
            } else if case .list(let id) = store.activeSelection, let l = store.project(id: id) {
                Text("~/tasks/").font(Typo.mono(14)).foregroundStyle(Theme.fgMute)
                Text(l.name).font(Typo.mono(18, weight: .semibold)).foregroundStyle(l.accent)
                if l.isShared {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(l.accent.opacity(0.8))
                        .help("Shared project")
                }
                Text("· \(store.countOpen(in: id))").font(Typo.mono(12)).foregroundStyle(Theme.fgFaint)
                Spacer()
                HStack(spacing: 8) {
                    Button(store.listModeLabel) { store.cycleListMode() }
                        .buttonStyle(.plain)
                        .font(Typo.mono(11))
                        .foregroundStyle(store.listModeIsDefault ? Theme.fgMute : Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))

                    Button("+ new") { onOpenCapture() }
                        .buttonStyle(.plain)
                        .font(Typo.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
                }
            } else { Spacer() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var endLabel: String {
        if let ctx = store.activeContextFilter { return ctx.rawValue }
        if case .list(let id) = store.activeSelection { return store.project(id: id)?.name ?? id }
        return ""
    }
}

// MARK: - Inspector

private struct MacInspector: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        Group {
            if let id = store.selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
                TaskInspectorContent(task: task)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.fgFaint)
                    Text("no task selected")
                        .font(Typo.mono(12))
                        .foregroundStyle(Theme.fgMute)
                    Text("click a row to inspect")
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.fgFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bgElev)
        .toolbar(.hidden, for: .windowToolbar)
    }
}
#endif
