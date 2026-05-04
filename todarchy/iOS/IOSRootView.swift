#if !os(macOS)
import SwiftUI

struct IOSRootView: View {
    @EnvironmentObject var store: TaskStore
    @State private var presenting: IOSSheet?
    @State private var showSettings = false
    @State private var quickAddText = ""
    @State private var quickAddFocused = false
    @StateObject private var undoToast = IOSUndoToast()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    IOSHeader(
                        openListSwitcher: { presenting = .listSwitcher },
                        openContextPicker: { presenting = .contextPicker },
                        openSettings: { showSettings = true }
                    )

                    if store.viewTasks.isEmpty {
                        IOSEmptyState()
                    } else {
                        IOSTaskList(
                            onTapTask: { t in
                                store.selectedTaskId = t.id
                                presenting = .taskDetail
                            },
                            onRequestDefer: { id in
                                // Defer one runloop — SwiftUI List's swipe
                                // retraction animation can swallow sheet
                                // presentation if we flip state during it.
                                DispatchQueue.main.async {
                                    presenting = .deferPicker(id)
                                }
                            }
                        )
                    }
                }

                // Tap-outside-to-dismiss layer. Appears only when the
                // quick-add field is focused; sits above the task list
                // but below the quick-add bar so tapping the bar itself
                // still works normally. Tapping anywhere else closes the
                // keyboard so the user can abandon the intent.
                if quickAddFocused {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { quickAddFocused = false }
                        .transition(.opacity)
                }

            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Bottom stack: undo toast (if any), chips, and quick-add
                // field. Living in the safe-area inset means the task
                // list automatically pads to avoid overlap.
                VStack(spacing: 0) {
                    IOSUndoToastView(toast: undoToast)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: undoToast.entry)

                    IOSListChips(
                        openContextPicker: { presenting = .contextPicker }
                    )
                    .padding(.top, 8)
                    .background(Theme.bg)

                    IOSQuickAddBar(
                        text: $quickAddText,
                        focused: $quickAddFocused,
                        commit: {
                            store.add(raw: quickAddText)
                            quickAddText = ""
                        },
                        onVoice: { presenting = .voiceCapture }
                    )
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .environmentObject(undoToast)
        .sheet(isPresented: $showSettings) {
            IOSSettingsSheet(
                persistence: TaskStorePersistence.shared,
                onClose: { showSettings = false }
            )
        }
        .sheet(item: $presenting, onDismiss: { store.selectedTaskId = nil }) { which in
            switch which {
            case .listSwitcher:
                ListSwitcherSheet(
                    onClose: { presenting = nil },
                    onRequestSettings: { showSettings = true }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .contextPicker:
                ContextPickerSheet(onClose: { presenting = nil })
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.visible)
            case .deferPicker(let id):
                DeferPickerSheet(taskId: id, onClose: { presenting = nil })
                    .presentationDetents([.height(380)])
                    .presentationDragIndicator(.visible)
            case .taskDetail:
                TaskDetailSheet(
                    onDefer: { id in presenting = .deferPicker(id) },
                    onClose: { presenting = nil }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .voiceCapture:
                VoiceCaptureSheet(onClose: { presenting = nil })
                    .presentationDetents([.height(360)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

enum IOSSheet: Identifiable, Hashable {
    case listSwitcher
    case contextPicker
    case deferPicker(String)
    case taskDetail
    case voiceCapture

    var id: String {
        switch self {
        case .listSwitcher: return "listSwitcher"
        case .contextPicker: return "contextPicker"
        case .deferPicker(let id): return "deferPicker-\(id)"
        case .taskDetail: return "taskDetail"
        case .voiceCapture: return "voiceCapture"
        }
    }
}

// MARK: - Header

private struct IOSHeader: View {
    @EnvironmentObject var store: TaskStore
    let openListSwitcher: () -> Void
    let openContextPicker: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: openListSwitcher) {
                HStack(spacing: 4) {
                    Text("~/tasks/")
                        .font(Typo.mono(15))
                        .foregroundStyle(Theme.fgMute)
                    Text(currentName)
                        .font(Typo.mono(17, weight: .semibold))
                        .foregroundStyle(currentColor)
                    if currentIsShared {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(currentColor.opacity(0.8))
                    }
                    Text("· \(count)")
                        .font(Typo.mono(13))
                        .foregroundStyle(Theme.fgFaint)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.fgMute)
                        .padding(.leading, 2)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: openContextPicker) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.activeContextFilter == nil ? Theme.fgMute : Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button(action: { store.cycleListMode() }) {
                Text(store.listModeLabel)
                    .font(Typo.mono(11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(store.listModeIsDefault ? Theme.fgMute : Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Sync indicator: small, quiet, far-right. Always present so
            // the user has ambient confidence that sync state is known.
            IOSSyncHeaderIndicator(onTap: openSettings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var currentName: String {
        if let ctx = store.activeContextFilter { return ctx.rawValue }
        switch store.activeSelection {
        case .list(let id): return store.project(id: id)?.name ?? id
        case .context(let ctx): return ctx.rawValue
        }
    }

    private var currentColor: Color {
        if let ctx = store.activeContextFilter { return ctx.color }
        switch store.activeSelection {
        case .list(let id): return store.project(id: id)?.accent ?? Theme.accent
        case .context(let ctx): return ctx.color
        }
    }

    private var currentIsShared: Bool {
        guard store.activeContextFilter == nil else { return false }
        if case .list(let id) = store.activeSelection {
            return store.project(id: id)?.isShared == true
        }
        return false
    }

    private var count: Int {
        if let ctx = store.activeContextFilter { return store.countOpen(ctx: ctx) }
        switch store.activeSelection {
        case .list(let id): return store.countOpen(in: id)
        case .context(let ctx): return store.countOpen(ctx: ctx)
        }
    }
}

// MARK: - List chips row

private struct IOSListChips: View {
    @EnvironmentObject var store: TaskStore
    let openContextPicker: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.allLists) { list in
                    chip(for: list)
                }
                Button(action: openContextPicker) {
                    HStack(spacing: 6) {
                        Text("@").font(Typo.mono(13, weight: .semibold))
                        Text("context").font(Typo.mono(12))
                    }
                    .foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(
                        Capsule().stroke(Theme.borderHi, style: StrokeStyle(lineWidth: 1, dash: [3]))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func chip(for list: ProjectItem) -> some View {
        let active: Bool = {
            guard store.activeContextFilter == nil else { return false }
            if case .list(let id) = store.activeSelection { return id == list.id }
            return false
        }()
        return Button {
            store.activeSelection = .list(list.id)
            store.activeContextFilter = nil
        } label: {
            HStack(spacing: 8) {
                ListDot(color: list.accent, glow: active)
                Text(list.name)
                    .font(Typo.mono(13))
                    .foregroundStyle(active ? Theme.fg : Theme.fgMute)
                if list.isShared {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle((active ? list.accent : Theme.fgMute).opacity(0.85))
                }
                Text("\(store.countOpen(in: list.id))")
                    .font(Typo.mono(12))
                    .foregroundStyle(active ? list.accent : Theme.fgFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(active ? list.accent.opacity(0.14) : .clear)
            )
            .overlay(
                Capsule()
                    .stroke(active ? list.accent.opacity(0.55) : Theme.border, lineWidth: 1)
            )
            .opacity(store.activeContextFilter == nil ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Task list

private struct IOSTaskList: View {
    @EnvironmentObject var store: TaskStore
    let onTapTask: (TaskItem) -> Void
    let onRequestDefer: (String) -> Void

    var body: some View {
        // List (not ScrollView/LazyVStack) because .swipeActions and
        // .onMove only activate on rows inside a SwiftUI List. Styling
        // below strips the default List chrome so the visual matches
        // the prior stack.
        List {
            ForEach(store.viewTasks) { task in
                IOSTaskRow(
                    task: task,
                    onTap: { onTapTask(task) },
                    onRequestDefer: { onRequestDefer(task.id) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                store.reorderView(from: source, to: destination)
            }
            Text("── end of \(endName) ──")
                .font(Typo.mono(11))
                .tracking(0.5)
                .foregroundStyle(Theme.fgFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .refreshable {
            await performSync()
        }
    }

    /// Pull-to-refresh action: coordinate with the sync daemon and merge.
    /// Surfaces any error via a transient flash on the sync settings page
    /// (via SyncSettings state).
    @MainActor
    private func performSync() async {
        SyncSettings.shared.beginSync()
        let result = await Task.detached {
            TaskStorePersistence.shared.syncNow()
        }.value
        SyncSettings.shared.endSync(result: result)
    }

    private var endName: String {
        if let ctx = store.activeContextFilter { return ctx.rawValue }
        if case .list(let id) = store.activeSelection { return store.project(id: id)?.name ?? id }
        return ""
    }
}

private struct IOSTaskRow: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var undoToast: IOSUndoToast
    let task: TaskItem
    let onTap: () -> Void
    let onRequestDefer: () -> Void

    var body: some View {
        TaskRow(
            task: task,
            listMeta: store.project(id: task.list),
            showList: store.activeContextFilter != nil,
            highlightedCtx: store.activeContextFilter,
            onToggle: { withAnimation(.easeInOut(duration: 0.18)) { store.toggleDone(task.id) } },
            onTapCtx: { ctx in
                if store.activeContextFilter == ctx {
                    store.activeContextFilter = nil
                } else {
                    store.activeContextFilter = ctx
                }
            }
        )
        .background(Theme.bg)
        .onTapGesture(perform: onTap)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.toggleDone(task.id)
            } label: {
                Label(task.isDone ? "Undo" : "Complete", systemImage: "checkmark")
            }
            .tint(Theme.success)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteWithToast()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                onRequestDefer()
            } label: {
                Label("Defer", systemImage: "moon")
            }
            .tint(Theme.purple)
        }
        .contextMenu {
            Button(task.isDone ? "Undo" : "Complete") { store.toggleDone(task.id) }
            Button("Defer…") { onRequestDefer() }
            Divider()
            Menu("Move to…") {
                ForEach(store.allLists.filter { $0.id != task.list }) { l in
                    Button(l.name) { store.move(task.id, toList: l.id) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { deleteWithToast() }
        }
    }

    private func deleteWithToast() {
        let title = task.title
        store.delete(task.id)
        undoToast.show(deletedTitle: title) { [weak store] in
            _ = store?.undo()
        }
    }
}

// MARK: - Empty state

private struct IOSEmptyState: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        VStack(spacing: 10) {
            Text("∅").font(Typo.mono(44)).foregroundStyle(Theme.fgFaint)
            Text(line1)
                .font(Typo.mono(14))
                .foregroundStyle(Theme.fgMute)
            Text("capture something. sort later.")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var line1: AttributedString {
        var a = AttributedString("~/tasks/")
        a.foregroundColor = Theme.fgMute
        var b = AttributedString(store.project(id: listId)?.name ?? "")
        b.foregroundColor = store.project(id: listId)?.accent ?? Theme.accent
        var c = AttributedString(" is empty")
        c.foregroundColor = Theme.fgMute
        return a + b + c
    }

    private var listId: String {
        if case .list(let id) = store.activeSelection { return id }
        return "inbox"
    }
}

// MARK: - Quick-add bar

private struct IOSQuickAddBar: View {
    @EnvironmentObject var store: TaskStore
    @Binding var text: String
    @Binding var focused: Bool
    @FocusState private var tfFocus: Bool
    let commit: () -> Void
    var onVoice: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if tfFocus {
                // Parsed preview above the input
                QuickAddPreview(text: text)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                TextField(text: $text, axis: .horizontal) {
                    Text("add task…")
                        .foregroundStyle(Theme.fgMute)
                }
                .font(Typo.mono(15))
                .foregroundStyle(Theme.fg)
                .focused($tfFocus)
                .submitLabel(.send)
                .onSubmit {
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    commit()
                }

                if tfFocus {
                    Button("save") {
                        commit()
                        tfFocus = false
                    }
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                    )
                } else {
                    Button(action: onVoice) {
                        Image(systemName: "mic")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add task by voice")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Theme.bgElev)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if tfFocus {
                QuickAddChips { token in
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        text = token + " "
                    } else {
                        text += " " + token
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: tfFocus)
        .onChange(of: tfFocus) { _, v in focused = v }
        // Two-way: parent can dismiss the keyboard by flipping the binding
        // to false (e.g. tap-outside gesture), and we'll drop the field
        // focus in response.
        .onChange(of: focused) { _, v in
            if tfFocus != v { tfFocus = v }
        }
    }
}

private struct QuickAddPreview: View {
    let text: String
    var body: some View {
        let parsed = QuickAddParser.parse(text)
        HStack(spacing: 8) {
            if !parsed.title.isEmpty {
                Text(parsed.title)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                if let c = parsed.ctx { CtxChip(ctx: c, highlighted: true) }
                if let d = parsed.due { DueChip(due: d) }
                if !parsed.note.isEmpty {
                    Text("/ \(parsed.note)")
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.fgFaint)
                        .lineLimit(1)
                }
            } else {
                Text("preview appears as you type…")
                    .font(Typo.mono(12))
                    .italic()
                    .foregroundStyle(Theme.fgFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06))
        .overlay(
            Rectangle()
                .strokeBorder(Theme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
        )
    }
}

private struct QuickAddChips: View {
    let insert: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TaskContext.allCases) { c in
                    chip(c.rawValue, color: c.color) { insert(c.rawValue) }
                }
                Divider().frame(height: 16).background(Theme.border)
                chip("!today", color: Theme.danger) { insert("!today") }
                chip("!tomorrow", color: Theme.warn) { insert("!tomorrow") }
                chip("!week", color: Theme.blue) { insert("!week") }
                Divider().frame(height: 16).background(Theme.border)
                chip("/ note", color: Theme.fgMute) { insert("/") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func chip(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typo.mono(12.5))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(
                    Capsule().stroke(color.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
#endif
