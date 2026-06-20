#if os(macOS)
import SwiftUI
import Combine

/// Identifiable wrapper so `.sheet(item:)` works with a task id.
struct SendToTarget: Identifiable, Equatable {
    let id: String
}

/// Filter + highlight logic for the "send to project" picker, extracted so
/// it's unit-testable without a view. Mirrors `CommandPaletteModel` and
/// reuses the same key monitor via `PaletteNavigable`.
final class SendToPickerModel: ObservableObject, PaletteNavigable {
    @Published var query: String = "" {
        didSet { clampHighlight() }
    }
    @Published private(set) var highlighted: Int = 0

    /// Candidate destination lists (the task's current list is excluded by
    /// the caller, so every row here is a real move).
    let lists: [ProjectItem]

    /// Invoked with the chosen list when a row is committed.
    var onCommit: ((ProjectItem) -> Void)?

    init(lists: [ProjectItem]) {
        self.lists = lists
    }

    var results: [ProjectItem] {
        guard !query.isEmpty else { return lists }
        let q = query.lowercased()
        return lists.filter { $0.name.lowercased().contains(q) }
    }

    var highlightedList: ProjectItem? {
        let r = results
        guard highlighted >= 0, highlighted < r.count else { return nil }
        return r[highlighted]
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

    /// Commit the highlighted list. Returns true if a list was chosen.
    @discardableResult
    func execute() -> Bool {
        guard let list = highlightedList else { return false }
        onCommit?(list)
        return true
    }

    private func clampHighlight() {
        let n = results.count
        if n == 0 { highlighted = 0; return }
        if highlighted >= n { highlighted = 0 }
    }
}

struct SendToPickerSheet: View {
    @EnvironmentObject var store: TaskStore
    let taskId: String
    let onClose: () -> Void

    @StateObject private var model: SendToPickerModel
    @StateObject private var keyMonitor = MacPaletteKeyMonitor()
    @FocusState private var fieldFocused: Bool

    init(taskId: String, lists: [ProjectItem], onClose: @escaping () -> Void) {
        self.taskId = taskId
        self.onClose = onClose
        _model = StateObject(wrappedValue: SendToPickerModel(lists: lists))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)

            HStack(spacing: 10) {
                Text("→")
                    .font(Typo.mono(18, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                TextField(text: $model.query) {
                    Text("send to project…")
                        .foregroundStyle(Theme.fgMute)
                }
                .textFieldStyle(.plain)
                .font(Typo.mono(16))
                .foregroundStyle(Theme.fg)
                .focused($fieldFocused)
                .onSubmit { commitSelection() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().background(Theme.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.results.isEmpty {
                            Text("no other projects")
                                .font(Typo.mono(12))
                                .italic()
                                .foregroundStyle(Theme.fgFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, list in
                                row(idx: idx, list: list)
                                    .id(list.id)
                            }
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
            model.onCommit = { list in
                store.move(taskId, toList: list.id)
            }
            keyMonitor.model = model
            keyMonitor.onClose = onClose
            keyMonitor.install()
            fieldFocused = true
        }
        .onDisappear { keyMonitor.uninstall() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SEND TO")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.purple)
            if let t = currentTask {
                Text(t.title)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                if let l = store.project(id: t.list) {
                    Text("(in \(l.name))")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgMute)
                }
            } else {
                Text("selected task").font(Typo.mono(13)).foregroundStyle(Theme.fgMute)
            }
            Spacer()
            Text("esc")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var currentTask: TaskItem? {
        store.tasks.first(where: { $0.id == taskId })
    }

    private func row(idx: Int, list: ProjectItem) -> some View {
        HStack(spacing: 8) {
            ListDot(color: list.accent)
            Text(list.name)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fg)
            Spacer()
            Text("\(store.countOpen(in: list.id))")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
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
}
#endif
