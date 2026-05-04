#if os(macOS)
import SwiftUI

/// Small modal for managing the user's `@context` chips. Add by typing
/// a name + Enter (or hitting +); remove or rename existing rows in
/// place. Mutations go through `TaskStore` so they persist via the
/// regular Automerge save pipeline.
struct ContextEditorSheet: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var error: String?
    @State private var renameTarget: TaskContext?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)
            list
            Divider().background(Theme.border)
            addBar
        }
        .frame(width: 380, height: 460)
        .background(Theme.bgElev)
    }

    private var header: some View {
        HStack {
            Text("contexts")
                .font(Typo.mono(13, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("\(store.contexts.count)")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.contexts) { ctx in
                    row(for: ctx)
                }
            }
        }
    }

    private func row(for ctx: TaskContext) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ctx.color)
                .frame(width: 8, height: 8)

            if renameTarget == ctx {
                TextField(ctx.rawValue, text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .tint(Theme.accent)
                    .onSubmit { commitRename(ctx) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(ctx.rawValue)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                Text("\(usageCount(ctx))")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
            }

            Spacer()

            if renameTarget == ctx {
                Button("Save") { commitRename(ctx) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.accent)
                Button("Cancel") { cancelRename() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
            } else {
                Button {
                    renameTarget = ctx
                    renameDraft = ctx.rawValue
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help("Rename")

                Button(role: .destructive) {
                    store.removeContext(ctx)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help("Remove (tasks keep their label)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("@")
                    .font(Typo.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("new context name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .tint(Theme.accent)
                    .onSubmit(commitDraft)
                Button {
                    commitDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            if let error {
                Text(error)
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func usageCount(_ ctx: TaskContext) -> Int {
        store.tasks.filter { $0.ctx == ctx }.count
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let ctx = TaskContext(rawValue: trimmed)
        if store.contexts.contains(ctx) {
            error = "\(ctx.rawValue) already exists."
            return
        }
        store.addContext(trimmed)
        draft = ""
        error = nil
    }

    private func commitRename(_ from: TaskContext) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { cancelRename(); return }
        if store.renameContext(from: from, to: trimmed) {
            cancelRename()
        } else {
            error = "couldn't rename — name may already exist"
        }
    }

    private func cancelRename() {
        renameTarget = nil
        renameDraft = ""
    }
}
#endif
