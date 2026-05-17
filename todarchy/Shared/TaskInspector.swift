import SwiftUI

/// Inspector panel content — used by both iPad (detail column) and macOS (inspector pane).
struct TaskInspectorContent: View {
    @EnvironmentObject var store: TaskStore
    let task: TaskItem

    @State private var commentState = CommentComposerState()
    @FocusState private var commentFocused: Bool
    @State private var bodyState = BodyEditorState()
    @FocusState private var bodyFocused: Bool

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

                // Body is the canonical long-form content — show it
                // above comments so it's visible without scrolling.
                bodySection

                commentsSection

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
                Menu {
                    ForEach(store.contexts) { ctx in
                        Button {
                            store.setContext(task.id, ctx: ctx)
                        } label: {
                            if task.ctx == ctx {
                                Label(ctx.rawValue, systemImage: "checkmark")
                            } else {
                                Text(ctx.rawValue)
                            }
                        }
                    }
                    if task.ctx != nil {
                        Divider()
                        Button("clear", role: .destructive) {
                            store.setContext(task.id, ctx: nil)
                        }
                    }
                } label: {
                    if let c = task.ctx {
                        CtxChip(ctx: c, highlighted: true)
                    } else {
                        Text("none  ▾")
                            .font(Typo.mono(12))
                            .foregroundStyle(Theme.fgMute)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            metaRow("due") {
                Menu {
                    ForEach(DueBucket.allCases) { bucket in
                        Button {
                            store.setDue(task.id, due: bucket)
                        } label: {
                            if task.due == bucket {
                                Label(bucket.label, systemImage: "checkmark")
                            } else {
                                Text(bucket.label)
                            }
                        }
                    }
                    if task.due != nil {
                        Divider()
                        Button("clear", role: .destructive) {
                            store.setDue(task.id, due: nil)
                        }
                    }
                } label: {
                    if let d = task.due {
                        DueChip(due: d)
                    } else {
                        Text("none  ▾")
                            .font(Typo.mono(12))
                            .foregroundStyle(Theme.fgMute)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
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

    // MARK: - Body

    /// Body content — formerly "note". Markdown source, rendered when
    /// not focused. Tap to edit. Mac/iPad both get this for free
    /// since the inspector is in `Shared/`; this also gives Mac users
    /// their first in-app way to edit notes (the previous inspector
    /// was read-only).
    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("BODY")
                    .font(Typo.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.fgMute)
                Spacer()
                if bodyState.isEditing {
                    Text("⎋ done")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgFaint)
                }
            }

            switch bodyState.display(canonical: task.note) {
            case .editing:
                TextEditor(text: $bodyState.draft)
                    .focused($bodyFocused)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(10)
                    .background(Theme.bgSoft)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .onAppear { bodyFocused = true }
                    .onChange(of: bodyState.draft) { _, v in
                        if v != task.note { store.setNote(task.id, note: v) }
                    }
                    .onChange(of: bodyFocused) { _, focused in
                        if !focused { bodyState.escape() }
                    }
                    .modifier(EscapeToDismiss { bodyState.escape() })
            case .emptyPlaceholder:
                Button {
                    bodyState.beginEditing(seed: "")
                } label: {
                    Text("tap to add body…")
                        .font(Typo.mono(12))
                        .italic()
                        .foregroundStyle(Theme.fgFaint)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                        .padding(10)
                        .background(Theme.bgSoft)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .preview:
                MarkdownText(raw: task.note)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bgSoft)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { bodyState.beginEditing(seed: task.note) }
            }
        }
        .onAppear { bodyState.syncFromCanonical(task.note) }
        .onChange(of: task.id) { _, _ in
            bodyState.escape()
            bodyState.syncFromCanonical(task.note)
        }
    }

    // MARK: - Comments

    private var commentsSection: some View {
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
                Text("no comments yet")
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

            commentComposer
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
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.bgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch commentState.display {
            case .editing:
                // axis: .vertical so the field grows for multi-line comments.
                // Plain Return inserts a newline; ⌘↵ posts via the keyboard
                // shortcut on the post button. Mirrors the macOS capture
                // window's convention.
                TextField("add a comment as \(CommentAuthor.current)…",
                          text: $commentState.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($commentFocused)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1...5)
                    .padding(8)
                    .background(Theme.bgSoft)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .onAppear { commentFocused = true }
                    .onChange(of: commentFocused) { _, focused in
                        if !focused && commentState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            commentState.escape()
                        }
                    }
                    .modifier(EscapeToDismiss { commentState.escape() })
            case .placeholder:
                Button {
                    commentState.beginEditing()
                } label: {
                    Text("add a comment as \(CommentAuthor.current)…")
                        .font(Typo.mono(12))
                        .italic()
                        .foregroundStyle(Theme.fgFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.bgSoft)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text(commentState.isFocused ? "⌘↵ post  ·  ⎋ done" : "⌘↵ post")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
                Spacer()
                Button(action: postComment) {
                    Text("post")
                        .font(Typo.mono(11, weight: .semibold))
                        .foregroundStyle(commentState.canPost ? Theme.bg : Theme.fgMute)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(commentState.canPost ? Theme.accent : Theme.bgSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!commentState.canPost)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onChange(of: task.id) { _, _ in commentState.escape() }
    }

    private func postComment() {
        guard commentState.canPost else { return }
        _ = store.addComment(taskId: task.id, text: commentState.draft)
        commentState.didPost()
    }
}

/// Wraps `.onExitCommand` so the shared inspector compiles on iOS,
/// where the modifier is unavailable. On iOS this is a no-op — the
/// system keyboard's dismiss gesture covers the same UX gap.
private struct EscapeToDismiss: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onExitCommand(perform: action)
        #else
        content
        #endif
    }
}
