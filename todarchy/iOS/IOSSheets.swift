#if !os(macOS)
import SwiftUI
import UIKit

// MARK: - List switcher

struct ListSwitcherSheet: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject var syncSettings = SyncSettings.shared
    @State private var search = ""
    @State private var pendingNameProjectId: String?
    /// True when the pending name edit is for a freshly-created project (so an
    /// empty commit deletes the blank shell). False when renaming an existing
    /// project (an empty commit just cancels, keeping the original name).
    @State private var pendingNameIsNew: Bool = false
    @State private var nameBuffer: String = ""
    @FocusState private var nameFieldFocused: Bool
    /// Transient banner at the top of the sheet for share outcomes.
    @State private var shareBanner: (text: String, isError: Bool)?
    /// Project the user is being asked to confirm-delete. Drives the
    /// destructive alert; nil dismisses.
    @State private var pendingDelete: ProjectItem?
    let onClose: () -> Void
    var onRequestSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.fgMute)
                TextField(text: $search) {
                    Text("search lists").foregroundStyle(Theme.fgMute)
                }
                .font(Typo.mono(14))
                .foregroundStyle(Theme.fg)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let banner = shareBanner {
                HStack(spacing: 8) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Theme.danger : Theme.success)
                    Text(banner.text)
                        .font(Typo.mono(12))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background((banner.isError ? Theme.danger : Theme.success).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("LISTS")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.allLists.filter { list in
                        // Skip the as-yet-unnamed project so it doesn't
                        // render as a blank row above the edit field.
                        guard list.id != pendingNameProjectId else { return false }
                        return search.isEmpty
                            || list.name.localizedCaseInsensitiveContains(search)
                    }) { list in
                        row(for: list)
                    }

                    if let id = pendingNameProjectId {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                            TextField("name this project…", text: $nameBuffer)
                                .font(Typo.mono(15, weight: .medium))
                                .foregroundStyle(Theme.fg)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($nameFieldFocused)
                                .submitLabel(.done)
                                .onSubmit { commitPendingName(id) }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    } else {
                        HStack {
                            Image(systemName: "plus")
                                .foregroundStyle(Theme.accent)
                            Text("New Project")
                                .font(Typo.mono(14, weight: .medium))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { beginNewProject() }
                    }

                    Button {
                        onClose()
                        // Wait for the list-switcher dismissal to finish so
                        // the settings sheet animates in cleanly.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onRequestSettings()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundStyle(Theme.fgMute)
                            Text("Settings")
                                .font(Typo.mono(14))
                                .foregroundStyle(Theme.fgDim)
                            Spacer()
                            if SyncSettings.shared.mode.kind != .localOnly {
                                Circle().fill(Theme.success).frame(width: 6, height: 6)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.fgFaint)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Theme.bgElev.ignoresSafeArea())
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
    }

    private func performDestructive(on project: ProjectItem) {
        if project.isShared {
            guard let manager = syncSettings.sharedProjectManager else {
                flashBanner("Sync isn't set up — can't leave a shared project.", isError: true)
                return
            }
            do {
                try store.leaveSharedProject(project.id, manager: manager)
            } catch let err as TaskStore.ShareError {
                flashBanner(err.errorDescription ?? "Couldn't leave shared project.", isError: true)
            } catch {
                flashBanner(error.localizedDescription, isError: true)
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

    private func beginNewProject() {
        let id = store.addProject(name: "")
        nameBuffer = ""
        pendingNameIsNew = true
        pendingNameProjectId = id
        // Focus on the next runloop so the field is in the hierarchy first.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func beginRename(_ list: ProjectItem) {
        nameBuffer = list.name
        pendingNameIsNew = false
        pendingNameProjectId = list.id
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitPendingName(_ id: String) {
        let trimmed = nameBuffer.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // A blank new project is an abandoned shell — remove it so we
            // don't leak nameless projects. A blank rename of an existing
            // project just cancels, leaving the original name intact.
            if pendingNameIsNew {
                store.deleteProject(id: id)
            }
        } else {
            store.renameProject(id: id, to: trimmed)
            if pendingNameIsNew {
                store.activeSelection = .list(id)
                store.activeContextFilter = nil
            }
        }
        pendingNameProjectId = nil
        pendingNameIsNew = false
        nameBuffer = ""
        nameFieldFocused = false
        onClose()
    }

    private func row(for list: ProjectItem) -> some View {
        let active: Bool = {
            if case .list(let id) = store.activeSelection { return id == list.id }
            return false
        }()
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(active ? list.accent : .clear)
                .frame(width: 3, height: 22)

            Image(systemName: list.icon)
                .foregroundStyle(list.accent)
                .frame(width: 22)

            Text(list.name)
                .font(Typo.mono(15, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.fg : Theme.fgDim)

            if list.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(list.accent.opacity(0.8))
                    .accessibilityLabel("Shared project")
            }
            if list.claudeAccess {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(list.accent.opacity(0.8))
                    .accessibilityLabel("Claude has access to this list")
            }

            Spacer()

            Text("\(store.countOpen(in: list.id))")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgFaint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.bgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            store.activeSelection = .list(list.id)
            store.activeContextFilter = nil
            onClose()
        }
        .contextMenu {
            // Claude-access toggle is available on every project,
            // including inbox + shared lists. Synced via main doc so
            // toggling from any device propagates to the Mac (which
            // runs the MCP server).
            Button {
                store.setClaudeAccess(id: list.id, enabled: !list.claudeAccess)
            } label: {
                Label(list.claudeAccess ? "Disable Claude access" : "Allow Claude access",
                      systemImage: list.claudeAccess ? "sparkles.slash" : "sparkles")
            }
            if list.isInbox {
                // Inbox can't be renamed/shared/deleted — Claude toggle
                // above is the only menu item here.
            } else if list.isShared {
                Button {
                    beginRename(list)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    handleShareTap(list)
                } label: {
                    Label("Copy share link", systemImage: "link")
                }
                Button(role: .destructive) {
                    pendingDelete = list
                } label: {
                    Label("Leave shared project", systemImage: "person.crop.circle.badge.xmark")
                }
            } else {
                Button {
                    beginRename(list)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    handleShareTap(list)
                } label: {
                    Label("Share…", systemImage: "person.crop.circle.badge.plus")
                }
                Button(role: .destructive) {
                    pendingDelete = list
                } label: {
                    Label("Delete project", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Share

    private func handleShareTap(_ project: ProjectItem) {
        guard let manager = syncSettings.sharedProjectManager else {
            flashBanner("Pick a sync folder in Settings first.", isError: true)
            return
        }
        do {
            let url: URL
            if project.isShared {
                guard let key = syncSettings.keyStore.load(for: project.id) else {
                    flashBanner("This project is flagged shared but we don't have its key on this device.",
                                isError: true)
                    return
                }
                url = ShareLink.encode(projectId: project.id, key: key)
            } else {
                url = try store.promoteToShared(project.id, manager: manager)
            }
            UIPasteboard.general.string = url.absoluteString
            flashBanner(project.isShared ? "Link copied. Send it to a collaborator."
                                         : "Shared — link copied to clipboard.",
                        isError: false)
        } catch let err as TaskStore.ShareError {
            flashBanner(err.errorDescription ?? "Couldn't share this project.", isError: true)
        } catch {
            flashBanner(error.localizedDescription, isError: true)
        }
    }

    private func flashBanner(_ text: String, isError: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            shareBanner = (text, isError)
        }
        let target = shareBanner
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if shareBanner?.text == target?.text {
                withAnimation(.easeInOut(duration: 0.18)) { shareBanner = nil }
            }
        }
    }
}

// MARK: - Context picker

struct ContextPickerSheet: View {
    @EnvironmentObject var store: TaskStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FILTER BY CONTEXT")
                        .font(Typo.mono(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.fgMute)
                    Text("show tasks across all lists")
                        .font(Typo.mono(14, weight: .medium))
                        .foregroundStyle(Theme.fg)
                }
                Spacer()
                if store.activeContextFilter != nil {
                    Button("clear") {
                        store.activeContextFilter = nil
                        onClose()
                    }
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(store.contexts) { ctx in
                    button(for: ctx)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)

            Text("tip: tap any @context chip on a task to toggle this filter")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgFaint)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgElev.ignoresSafeArea())
    }

    private func button(for ctx: TaskContext) -> some View {
        let active = store.activeContextFilter == ctx
        let count = store.countOpen(ctx: ctx)
        return Button {
            if active {
                store.activeContextFilter = nil
            } else {
                store.activeContextFilter = ctx
            }
            onClose()
        } label: {
            HStack {
                HStack(spacing: 8) {
                    ListDot(color: ctx.color, glow: active, size: 8)
                    Text(ctx.rawValue)
                        .font(Typo.mono(14, weight: .semibold))
                        .foregroundStyle(ctx.color)
                }
                Spacer()
                Text("\(count)")
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(count > 0 ? ctx.color : Theme.fgFaint)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(active ? ctx.color.opacity(0.18) : Theme.bgSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? ctx.color.opacity(0.55) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Defer picker

struct DeferPickerSheet: View {
    @EnvironmentObject var store: TaskStore
    let taskId: String
    let onClose: () -> Void

    @State private var custom = Date().addingTimeInterval(24 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DEFER UNTIL")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                preset("Later today", resolve: laterToday)
                preset("Tomorrow", resolve: tomorrow9)
                preset("This weekend", resolve: weekendAt9)
                preset("Next week", resolve: nextMonday9)
                preset("Two weeks", resolve: plusDays(14))
                preset("Next month", resolve: plusDays(30))
            }
            .padding(.horizontal, 12)

            HStack {
                Text("or pick a date")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                Spacer()
                DatePicker("", selection: $custom, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack {
                Button("clear defer") {
                    store.clearDefer(taskId)
                    onClose()
                }
                .font(Typo.mono(12))
                .foregroundStyle(Theme.danger)
                Spacer()
                Button {
                    store.defer_(taskId, until: custom)
                    onClose()
                } label: {
                    Text("defer →")
                        .font(Typo.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Theme.bgElev.ignoresSafeArea())
    }

    private func preset(_ label: String, resolve: @autoclosure () -> Date) -> some View {
        let d = resolve()
        let f: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "EEE, MMM d"
            return df
        }()
        return Button {
            store.defer_(taskId, until: d)
            onClose()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(Typo.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(f.string(from: d).lowercased())
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.bgSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func plusDays(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: Date()) ?? Date()
    }

    private var laterToday: Date {
        let cal = Calendar.current
        let now = Date()
        let eod = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3600 * 4)
        return eod > now ? eod : now.addingTimeInterval(3600 * 2)
    }

    private var tomorrow9: Date {
        DeferParser.tomorrow()
    }

    private var weekendAt9: Date {
        let cal = Calendar.current
        var c = DateComponents(); c.weekday = 7; c.hour = 9
        return cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? plusDays(3)
    }

    private var nextMonday9: Date {
        let cal = Calendar.current
        var c = DateComponents(); c.weekday = 2; c.hour = 9
        return cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? plusDays(7)
    }
}

// MARK: - Task detail

struct TaskDetailSheet: View {
    @EnvironmentObject var store: TaskStore
    let onDefer: (String) -> Void
    let onClose: () -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var commentDraft = ""
    @FocusState private var commentFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let task = selectedTask {
                    header(task: task)

                    titleEditor(task: task)
                    noteEditor(task: task)

                    commentsSection(task: task)

                    meta(task: task)

                    actions(task: task)
                } else {
                    Text("No task selected")
                        .font(Typo.mono(13))
                        .foregroundStyle(Theme.fgMute)
                        .padding(30)
                }
            }
            .padding(20)
        }
        .background(Theme.bgElev.ignoresSafeArea())
        .onAppear {
            if let t = selectedTask {
                title = t.title
                note = t.note
            }
        }
        .onChange(of: store.selectedTaskId) { _, _ in
            if let t = selectedTask {
                title = t.title
                note = t.note
            }
        }
    }

    private var selectedTask: TaskItem? {
        guard let id = store.selectedTaskId else { return nil }
        return store.tasks.first(where: { $0.id == id })
    }

    private func header(task: TaskItem) -> some View {
        HStack {
            Text(task.isDone ? "COMPLETED" : (task.isDeferred ? "DEFERRED" : "SELECTED"))
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(task.isDone ? Theme.success : (task.isDeferred ? Theme.purple : Theme.fgMute))
            Spacer()
            Text("id \(String(task.id.prefix(6)))")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
        }
    }

    private func titleEditor(task: TaskItem) -> some View {
        TextField("", text: $title, axis: .vertical)
            .font(Typo.mono(22, weight: .semibold))
            .foregroundStyle(Theme.fg)
            .onSubmit { store.setTitle(task.id, title: title) }
            .onChange(of: title) { _, v in store.setTitle(task.id, title: v) }
    }

    private func commentsSection(task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("COMMENTS")
                    .font(Typo.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.fgMute)
                if !task.comments.isEmpty {
                    Text("(\(task.comments.count))")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgFaint)
                }
            }

            if task.comments.isEmpty {
                Text("No comments yet.")
                    .font(Typo.mono(11))
                    .italic()
                    .foregroundStyle(Theme.fgFaint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.comments) { c in
                        commentRow(c)
                    }
                }
            }

            commentComposer(task: task)
        }
    }

    private func commentRow(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(c.author)
                    .font(Typo.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(TimeAgo.short(c.createdAt))
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
            }
            Text(c.text)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.bgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func commentComposer(task: TaskItem) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("add a comment as \(CommentAuthor.current)…",
                      text: $commentDraft, axis: .vertical)
                .focused($commentFocused)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fg)
                .lineLimit(1...4)
                .padding(10)
                .background(Theme.bgSoft)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            Button {
                _ = store.addComment(taskId: task.id, text: commentDraft)
                commentDraft = ""
                commentFocused = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canPostComment ? Theme.accent : Theme.fgMute)
            }
            .buttonStyle(.plain)
            .disabled(!canPostComment)
            .accessibilityLabel("Post comment")
        }
    }

    private var canPostComment: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func noteEditor(task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BODY")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
            // Focus-based toggle: tap to edit raw markdown, blur to
            // see the rendered preview. Keeps the source visible
            // while typing (so the user can edit the markdown) and
            // shows formatting otherwise (so it reads naturally).
            if noteFocused || note.isEmpty {
                TextEditor(text: $note)
                    .focused($noteFocused)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fgDim)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(10)
                    .background(Theme.bgSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1)
                    )
                    .onChange(of: note) { _, v in store.setNote(task.id, note: v) }
            } else {
                MarkdownText(raw: note)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.bgSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { noteFocused = true }
            }
        }
    }

    private func meta(task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("META")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)

            HStack {
                Text("list").font(Typo.mono(12)).foregroundStyle(Theme.fgMute).frame(width: 70, alignment: .leading)
                Menu {
                    ForEach(store.allLists) { l in
                        Button(l.name) { store.move(task.id, toList: l.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let l = store.project(id: task.list) {
                            ListDot(color: l.accent)
                            Text(l.name).foregroundStyle(Theme.fg)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                }
            }

            HStack {
                Text("context").font(Typo.mono(12)).foregroundStyle(Theme.fgMute).frame(width: 70, alignment: .leading)
                Menu {
                    Button("none") { store.setContext(task.id, ctx: nil) }
                    ForEach(store.contexts) { c in
                        Button(c.rawValue) { store.setContext(task.id, ctx: c) }
                    }
                } label: {
                    if let c = task.ctx {
                        CtxChip(ctx: c, highlighted: true)
                    } else {
                        Text("none").font(Typo.mono(13)).foregroundStyle(Theme.fgMute)
                    }
                }
            }

            HStack {
                Text("due").font(Typo.mono(12)).foregroundStyle(Theme.fgMute).frame(width: 70, alignment: .leading)
                Menu {
                    Button("none") { store.setDue(task.id, due: nil) }
                    ForEach(DueBucket.allCases) { d in
                        Button(d.label) { store.setDue(task.id, due: d) }
                    }
                } label: {
                    if let d = task.due { DueChip(due: d) }
                    else { Text("none").font(Typo.mono(13)).foregroundStyle(Theme.fgMute) }
                }
            }

            if let d = task.deferUntil, d > Date() {
                HStack {
                    Text("deferred").font(Typo.mono(12)).foregroundStyle(Theme.fgMute).frame(width: 70, alignment: .leading)
                    DeferChip(date: d)
                }
            }

            HStack {
                Text("created").font(Typo.mono(12)).foregroundStyle(Theme.fgMute).frame(width: 70, alignment: .leading)
                Text(TimeAgo.short(task.created) + " ago")
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fgDim)
            }
        }
    }

    private func actions(task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Button {
                store.toggleDone(task.id)
            } label: {
                label(task.isDone ? "undo" : "complete",
                      icon: "checkmark",
                      color: Theme.success)
            }.buttonStyle(.plain)

            Button {
                onDefer(task.id)
            } label: {
                label("defer", icon: "moon", color: Theme.purple)
            }.buttonStyle(.plain)

            Button {
                store.delete(task.id)
                onClose()
            } label: {
                label("delete", icon: "trash", color: Theme.danger)
            }.buttonStyle(.plain)
        }
    }

    private func label(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).font(Typo.mono(13, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
#endif
