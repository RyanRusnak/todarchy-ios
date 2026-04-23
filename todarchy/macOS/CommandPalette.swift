#if os(macOS)
import SwiftUI
import Combine

struct PaletteCommand: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let hint: String?
    let action: () -> Void

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: PaletteCommand, rhs: PaletteCommand) -> Bool { lhs.name == rhs.name }
}

/// Extracted so the palette's filter + selection logic is unit-testable without a view.
final class CommandPaletteModel: ObservableObject {
    @Published var query: String = "" {
        didSet { clampHighlight() }
    }
    @Published private(set) var highlighted: Int = 0
    var allCommands: [PaletteCommand] = []

    init(commands: [PaletteCommand] = []) {
        self.allCommands = commands
    }

    var results: [PaletteCommand] {
        guard !query.isEmpty else { return allCommands }
        let q = query.lowercased()
        return allCommands.filter { $0.name.lowercased().contains(q) }
    }

    func moveDown() {
        let n = results.count
        guard n > 0 else { highlighted = 0; return }
        highlighted = (highlighted + 1) % n
    }

    func moveUp() {
        let n = results.count
        guard n > 0 else { highlighted = 0; return }
        highlighted = (highlighted - 1 + n) % n
    }

    func setHighlight(_ idx: Int) {
        highlighted = max(0, min(idx, max(results.count - 1, 0)))
    }

    /// Executes the currently highlighted command. Returns true on success.
    @discardableResult
    func execute() -> Bool {
        let r = results
        guard highlighted >= 0, highlighted < r.count else { return false }
        r[highlighted].action()
        return true
    }

    private func clampHighlight() {
        let n = results.count
        if n == 0 { highlighted = 0; return }
        if highlighted >= n { highlighted = 0 }
    }
}

struct CommandPalette: View {
    @EnvironmentObject var store: TaskStore
    @StateObject private var model = CommandPaletteModel()
    @StateObject private var keyMonitor = MacPaletteKeyMonitor()
    @FocusState private var fieldFocused: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(":")
                    .font(Typo.mono(20, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                TextField(text: $model.query) {
                    Text("search commands…")
                        .foregroundStyle(Theme.fgMute)
                }
                .textFieldStyle(.plain)
                .font(Typo.mono(16))
                .foregroundStyle(Theme.fg)
                .focused($fieldFocused)
                .onSubmit { commitSelection() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().background(Theme.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, cmd in
                            row(idx: idx, cmd: cmd)
                                .id(cmd.id)
                        }
                    }
                }
                .background(Theme.bgElev)
                .onChange(of: model.highlighted) { _, newValue in
                    guard newValue < model.results.count else { return }
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(model.results[newValue].id, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.borderHi, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            model.allCommands = buildCommands()
            keyMonitor.model = model
            keyMonitor.onClose = onClose
            keyMonitor.install()
            fieldFocused = true
        }
        .onDisappear { keyMonitor.uninstall() }
    }

    private func row(idx: Int, cmd: PaletteCommand) -> some View {
        HStack {
            Text(cmd.name)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fg)
            Spacer()
            if let hint = cmd.hint {
                Text(hint)
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.borderHi, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(idx == model.highlighted ? Theme.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.setHighlight(idx)
            commitSelection()
        }
    }

    private func commitSelection() {
        if model.execute() { onClose() }
    }

    private func buildCommands() -> [PaletteCommand] {
        var cmds: [PaletteCommand] = [
            .init(name: "New Task", hint: "⌘N") {
                NotificationCenter.default.post(name: .todarchyOpenCapture, object: nil)
            },
            .init(name: "Go to Inbox", hint: "0") {
                store.activeSelection = .list("inbox")
                store.activeContextFilter = nil
            },
            .init(name: "Toggle Inspector", hint: "⌥⌘I") {
                NotificationCenter.default.post(name: .todarchyToggleInspector, object: nil)
            },
            .init(name: "Toggle Show Done", hint: nil) { store.showDone.toggle() },
            .init(name: "Toggle Show Deferred", hint: nil) { store.showDeferred.toggle() },
            .init(name: "Complete Selected", hint: "x") { store.toggleSelectedDone() },
            .init(name: "Defer Selected 24h", hint: "s") { store.deferSelected() },
            .init(name: "Delete Selected", hint: "⌫") { store.deleteSelected() },
            .init(name: "Manage Projects", hint: "gn") {
                NotificationCenter.default.post(name: .todarchyOpenProjectEditor, object: nil)
            },
            .init(name: "Defer Selected…", hint: "s") {
                NotificationCenter.default.post(name: .todarchyOpenDeferPicker, object: nil)
            },
            .init(name: "Edit Selected", hint: "e") {
                if let sid = store.selectedTaskId { store.editingTaskId = sid }
            },
            .init(name: "Indent Selected", hint: "⇥") { store.indentSelected() },
            .init(name: "Outdent Selected", hint: "⇧⇥") { store.outdentSelected() },
            .init(name: "Collapse/Expand Selected", hint: "z") { store.toggleCollapseSelected() },
        ]
        // Theme switchers. Update the static palette BEFORE writing
        // @AppStorage so the `.id(themeName)` rebuild on the root view
        // picks up the new palette without a stale-frame flash.
        for palette in ThemePalette.allPalettes {
            cmds.append(.init(name: "Theme: \(palette.id)", hint: nil) {
                ThemePalette.current = palette
                UserDefaults.standard.set(palette.id, forKey: "theme.name")
            })
        }
        cmds.append(.init(name: "Theme: next", hint: nil) {
            let current = UserDefaults.standard.string(forKey: "theme.name") ?? ThemePalette.tokyoNight.id
            let all = ThemePalette.allPalettes
            let idx = all.firstIndex(where: { $0.id == current }) ?? 0
            let next = all[(idx + 1) % all.count]
            ThemePalette.current = next
            UserDefaults.standard.set(next.id, forKey: "theme.name")
        })

        // Sync.
        cmds.append(.init(name: "Sync Now", hint: "⌘R") {
            NotificationCenter.default.post(name: .todarchySyncNow, object: nil)
        })

        // Voice capture.
        cmds.append(.init(name: "New Task by Voice", hint: "⌘⇧V") {
            NotificationCenter.default.post(name: .todarchyOpenVoiceCapture, object: nil)
        })

        // Export / import.
        cmds.append(.init(name: "Export JSON…", hint: nil) {
            ExportImportActions.exportJSON(store: store)
        })
        cmds.append(.init(name: "Export Markdown…", hint: nil) {
            ExportImportActions.exportMarkdown(store: store)
        })
        cmds.append(.init(name: "Import JSON…", hint: nil) {
            ExportImportActions.importJSON(store: store)
        })
        for (i, p) in store.projects.enumerated() {
            cmds.append(.init(name: "Go to \(p.name)", hint: "\(i + 1)") {
                store.activeSelection = .list(p.id)
                store.activeContextFilter = nil
            })
        }
        for c in TaskContext.allCases {
            cmds.append(.init(name: "Filter: \(c.rawValue)", hint: nil) {
                store.activeContextFilter = c
            })
        }
        return cmds
    }
}
#endif
