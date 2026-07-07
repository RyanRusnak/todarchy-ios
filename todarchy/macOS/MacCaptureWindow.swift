#if os(macOS)
import SwiftUI

struct MacCaptureWindow: View {
    @EnvironmentObject var store: TaskStore
    @Binding var text: String
    @FocusState private var focus: Bool
    /// `stayOpen = true` is the "save+" / batch-capture flow: commit
    /// the task and keep the capture sheet open with the field still
    /// focused so the user can type the next one. `false` is the
    /// normal one-shot save.
    let onCommit: (_ stayOpen: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("quick entry →")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                if case .list(let id) = store.activeSelection, let l = store.project(id: id) {
                    Text("~/tasks/\(l.name)")
                        .font(Typo.mono(11, weight: .semibold))
                        .foregroundStyle(l.accent)
                }
                Spacer()
                Text("esc").font(Typo.mono(10)).foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1))
            }

            HStack(alignment: .center) {
                Text("+").font(Typo.mono(20)).foregroundStyle(Theme.accent)
                TextField(text: $text, axis: .vertical) {
                    Text("call mom @phone !today /remember to ask about flights")
                        .foregroundStyle(Theme.fgMute)
                }
                .textFieldStyle(.plain)
                .font(Typo.mono(16))
                .foregroundStyle(Theme.fg)
                .focused($focus)
                .lineLimit(1...8)
                .onSubmit {
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onCommit(false)
                }
                .onExitCommand { onCancel() }
            }
            .padding(10)
            .background(Theme.bgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            let parsed = QuickAddParser.parse(text)
            HStack(spacing: 8) {
                if !parsed.title.isEmpty {
                    Text(parsed.title).font(Typo.mono(12)).foregroundStyle(Theme.fg)
                    if let c = parsed.ctx { CtxChip(ctx: c, highlighted: true) }
                    if let d = parsed.due { DueChip(due: d) }
                    if !parsed.note.isEmpty {
                        Text("/ \(parsed.note)").font(Typo.mono(11)).foregroundStyle(Theme.fgFaint)
                    }
                } else {
                    Text("preview appears as you type…")
                        .font(Typo.mono(11))
                        .italic()
                        .foregroundStyle(Theme.fgFaint)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )

            HStack {
                Text("⌘↵ save").font(Typo.mono(10)).foregroundStyle(Theme.fgFaint)
                Text("⌘⇧↵ save+").font(Typo.mono(10)).foregroundStyle(Theme.fgFaint)
                Text("⎋ cancel").font(Typo.mono(10)).foregroundStyle(Theme.fgFaint)
                Text("⇥ list").font(Typo.mono(10)).foregroundStyle(Theme.fgFaint)
                Spacer()
                Button("cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.bgSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // save+ = commit and keep the capture window open
                // for the next task. Outlined treatment so it reads
                // as the secondary action next to the primary save.
                Button("save+") { onCommit(true) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    .disabled(parsed.title.isEmpty)
                    .opacity(parsed.title.isEmpty ? 0.5 : 1)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])

                Button("save →") { onCommit(false) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(parsed.title.isEmpty)
                    .opacity(parsed.title.isEmpty ? 0.5 : 1)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(20)
        .background(Theme.bgElev)
        .onAppear { focus = true }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        TabView {
            SyncSettingsView(persistence: TaskStorePersistence.shared)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            SyncDiagnosticsView()
                .tabItem { Label("Debug", systemImage: "wrench.and.screwdriver") }
            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.bg)
    }

    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("todokase")
                .font(Typo.mono(18, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("Theme: \(ThemePalette.current.id)")
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fgDim)
            Text("Font: JetBrains Mono")
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fgDim)
            Text("Min iOS 17 · Min macOS 14")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgMute)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }
}
#endif
