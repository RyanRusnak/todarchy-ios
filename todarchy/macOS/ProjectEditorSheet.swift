#if os(macOS)
import SwiftUI
import AppKit

struct ProjectEditorSheet: View {
    @EnvironmentObject var store: TaskStore
    let onClose: () -> Void

    @ObservedObject var syncSettings = SyncSettings.shared
    @State private var editingId: String?
    @State private var editBuffer: String = ""
    @State private var pendingDelete: ProjectItem?
    @FocusState private var editFieldFocus: Bool
    /// id of the project whose share-link was just copied. Drives the
    /// brief "copied ✓" affordance on its row.
    @State private var lastCopiedId: String?
    /// Transient error surfaced after a failed promotion (no sync
    /// folder, key persistence failed, etc.). Cleared on next action.
    @State private var shareError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECTS")
                    .font(Typo.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.fgMute)
                Spacer()
                Button("+ new") { addNew() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Button("done") { onClose() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgMute)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().background(Theme.border)

            if let message = shareError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.fgDim)
                    Spacer()
                    Button("dismiss") { shareError = nil }
                        .buttonStyle(.plain)
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgMute)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Theme.danger.opacity(0.08))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { idx, project in
                        row(for: project, idx: idx)
                    }
                    if store.projects.isEmpty {
                        Text("no projects yet — press + new above")
                            .font(Typo.mono(12))
                            .italic()
                            .foregroundStyle(Theme.fgFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
            }
        }
        .frame(minHeight: 320)
        .background(Theme.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.borderHi, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            "Delete project?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button("Delete \(project.name) and its tasks", role: .destructive) {
                store.deleteProject(id: project.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { project in
            let count = store.tasks.filter { $0.list == project.id }.count
            Text(count > 0 ? "This project has \(count) tasks. They'll be deleted."
                            : "This project is empty.")
        }
    }

    private func row(for project: ProjectItem, idx: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: project.icon)
                .foregroundStyle(project.accent)
                .frame(width: 20)

            if editingId == project.id {
                TextField("name this project…", text: $editBuffer)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                    .focused($editFieldFocus)
                    .onSubmit { commitEdit(project.id) }
                    .onExitCommand { cancelEdit(project.id) }
            } else {
                Text(project.name)
                    .font(Typo.mono(13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("\(store.countOpen(in: project.id)) tasks")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgFaint)
            }

            Spacer()

            // Color picker
            HStack(spacing: 4) {
                ForEach(accentSwatches, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(project.accentHex == hex ? Theme.fg : .clear, lineWidth: 1.5)
                        )
                        .onTapGesture {
                            store.updateProjectAccent(id: project.id, hex: hex)
                        }
                }
            }

            Button {
                editingId = project.id
                editBuffer = project.name
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.fgMute)
            }
            .buttonStyle(.plain)

            shareButton(for: project)

            Button(role: .destructive) {
                pendingDelete = project
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1)
        }
    }

    private var accentSwatches: [UInt32] {
        [0x7AA2F7, 0xBB9AF7, 0x9ECE6A, 0xE0AF68, 0xF7768E, 0x7DCFFF, 0xFF9E64]
    }

    private func addNew() {
        let id = store.addProject(name: "", accent: Theme.accent, icon: "folder")
        editingId = id
        editBuffer = ""
        // Focus on the next runloop — the row needs to render first so
        // SwiftUI has the field in the hierarchy to accept focus.
        DispatchQueue.main.async { editFieldFocus = true }
    }

    private func commitEdit(_ id: String) {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Empty submit on a freshly-created project = abandon; delete
            // the shell so the user isn't left with a blank entry.
            if store.projects.first(where: { $0.id == id })?.name.isEmpty == true {
                store.deleteProject(id: id)
            }
        } else {
            store.renameProject(id: id, to: trimmed)
        }
        editingId = nil
    }

    private func cancelEdit(_ id: String) {
        // Esc during a fresh-create = abandon + delete.
        if store.projects.first(where: { $0.id == id })?.name.isEmpty == true {
            store.deleteProject(id: id)
        }
        editingId = nil
    }

    // MARK: - Share

    @ViewBuilder
    private func shareButton(for project: ProjectItem) -> some View {
        let copied = lastCopiedId == project.id
        let disabled = syncSettings.sharedProjectManager == nil || project.isInbox
        Button {
            handleShareTap(project)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark"
                                         : (project.isShared ? "person.2.fill" : "person.crop.circle.badge.plus"))
                Text(copied ? "copied"
                            : (project.isShared ? "link" : "share"))
                    .font(Typo.mono(11, weight: .semibold))
            }
            .foregroundStyle(copied ? Theme.success
                                     : (project.isShared ? Theme.accent : Theme.fgMute))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1.0)
        .help(disabled ? "Pick a sync folder in Settings → Sync to share."
                       : (project.isShared ? "Copy share link to clipboard"
                                            : "Generate a share link for this project"))
    }

    private func handleShareTap(_ project: ProjectItem) {
        guard let manager = syncSettings.sharedProjectManager else {
            shareError = "Pick a sync folder in Settings → Sync first."
            return
        }
        shareError = nil
        do {
            let url: URL
            if project.isShared {
                // Already shared — re-read the key and regenerate the
                // link. Handy for sending it to another collaborator
                // later, or re-copying after closing the clipboard.
                guard let key = syncSettings.keyStore.load(for: project.id) else {
                    shareError = "This project is flagged shared but we don't have its key on this device."
                    return
                }
                url = ShareLink.encode(projectId: project.id, key: key)
            } else {
                url = try store.promoteToShared(project.id, manager: manager)
            }
            copyToClipboard(url.absoluteString)
            flashCopied(for: project.id)
        } catch let err as TaskStore.ShareError {
            shareError = err.errorDescription ?? "Couldn't share this project."
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func flashCopied(for id: String) {
        lastCopiedId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if lastCopiedId == id { lastCopiedId = nil }
        }
    }
}

extension TaskStore {
    /// Change a project's accent color.
    func updateProjectAccent(id: String, hex: UInt32) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].accentHex = hex
    }
}
#endif
