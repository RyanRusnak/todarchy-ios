#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Model

@MainActor
final class TaskSearchModel: ObservableObject {
    @Published var query: String = "" {
        didSet { clampHighlight() }
    }
    @Published private(set) var highlighted: Int = 0
    weak var store: TaskStore?

    /// Matching open tasks, ranked by fuzzy score against title + notes + ctx.
    /// Title matches are weighted higher than note/context matches.
    var results: [TaskItem] {
        guard let store = store, !query.isEmpty else { return [] }
        let q = query.lowercased()
        return store.tasks
            .filter { !$0.isDone }
            .compactMap { task -> (TaskItem, Double)? in
                let titleScore = Self.fuzzyScore(needle: q, haystack: task.title.lowercased()).map { $0 * 2.0 }
                let noteScore = Self.fuzzyScore(needle: q, haystack: task.note.lowercased())
                let ctxScore = task.ctx.flatMap {
                    Self.fuzzyScore(needle: q, haystack: $0.rawValue.lowercased())
                }
                let best = [titleScore, noteScore, ctxScore].compactMap { $0 }.max()
                return best.map { (task, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
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

    /// Returns the currently highlighted task, or nil if results are empty.
    func commit() -> TaskItem? {
        let r = results
        guard highlighted >= 0, highlighted < r.count else { return nil }
        return r[highlighted]
    }

    private func clampHighlight() {
        let n = results.count
        if n == 0 { highlighted = 0; return }
        if highlighted >= n { highlighted = 0 }
    }

    /// Char-in-order fuzzy score. Higher is better. Returns nil for no match.
    static func fuzzyScore(needle: String, haystack: String) -> Double? {
        guard !needle.isEmpty else { return 0.0001 }
        var hi = haystack.startIndex
        var score: Double = 0
        var streak: Double = 0
        for c in needle {
            guard let idx = haystack[hi...].firstIndex(of: c) else { return nil }
            let gap = haystack.distance(from: hi, to: idx)
            score += 1.0 / (1.0 + Double(gap))
            if gap == 0 { streak += 1; score += streak * 0.5 }
            else { streak = 0 }
            hi = haystack.index(after: idx)
        }
        return score
    }
}

// MARK: - Key monitor for the search sheet (reuses PaletteKeyRouter)

@MainActor
final class MacSearchKeyMonitor: ObservableObject {
    weak var model: TaskSearchModel?
    var onCommit: ((TaskItem) -> Void)?
    var onClose: (() -> Void)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = KeyModifiers.from(event.modifierFlags)
        let intent = PaletteKeyRouter.route(chars: chars, keyCode: event.keyCode, modifiers: mods)
        return apply(intent)
    }

    @discardableResult
    func apply(_ intent: PaletteKeyIntent) -> Bool {
        switch intent {
        case .moveUp: model?.moveUp(); return true
        case .moveDown: model?.moveDown(); return true
        case .commit:
            guard let task = model?.commit() else { return false }
            onCommit?(task)
            return true
        case .cancel: onClose?(); return true
        case .pass: return false
        }
    }
}

// MARK: - View

struct TaskSearchSheet: View {
    @EnvironmentObject var store: TaskStore
    @StateObject private var model = TaskSearchModel()
    @StateObject private var keyMonitor = MacSearchKeyMonitor()
    @FocusState private var fieldFocused: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("/")
                    .font(Typo.mono(20, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                TextField(text: $model.query) {
                    Text("search tasks…")
                        .foregroundStyle(Theme.fgMute)
                }
                .textFieldStyle(.plain)
                .font(Typo.mono(16))
                .foregroundStyle(Theme.fg)
                .focused($fieldFocused)
                .onSubmit { commit() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().background(Theme.border)

            if model.query.isEmpty {
                emptyHint
            } else if model.results.isEmpty {
                noMatchesHint
            } else {
                resultsList
            }
        }
        .background(Theme.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.borderHi, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            model.store = store
            keyMonitor.model = model
            keyMonitor.onCommit = { task in
                jumpTo(task)
                onClose()
            }
            keyMonitor.onClose = onClose
            keyMonitor.install()
            fieldFocused = true
        }
        .onDisappear { keyMonitor.uninstall() }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Text("type to search task titles")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgMute)
            Text("↑↓ to navigate · ↵ to jump · esc to close")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bgElev)
    }

    private var noMatchesHint: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: 40)
            Text("no matches")
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgMute)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bgElev)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, task in
                        row(idx: idx, task: task)
                            .id(task.id)
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

    private func row(idx: Int, task: TaskItem) -> some View {
        let listMeta = store.project(id: task.list)
        return HStack(spacing: 10) {
            if let listMeta {
                ListDot(color: listMeta.accent)
                Text(listMeta.name)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                    .frame(width: 80, alignment: .leading)
            }
            Text(task.title)
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
            Spacer()
            if let c = task.ctx {
                CtxChip(ctx: c, highlighted: false)
            }
            if let d = task.due {
                DueChip(due: d)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(idx == model.highlighted ? Theme.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.setHighlight(idx)
            commit()
        }
    }

    private func commit() {
        guard let task = model.commit() else { return }
        jumpTo(task)
        onClose()
    }

    private func jumpTo(_ task: TaskItem) {
        store.activeContextFilter = nil
        store.activeSelection = .list(task.list)
        store.selectedTaskId = task.id
    }
}
#endif
