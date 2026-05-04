import Foundation
import Combine
import SwiftUI

final class TaskStore: ObservableObject {
    @Published var tasks: [TaskItem] { didSet { if !isApplyingDiskState { scheduleSave() } } }
    @Published var projects: [ProjectItem] { didSet { if !isApplyingDiskState { scheduleSave() } } }

    /// True while `refreshFromDisk` is reassigning `tasks`/`projects` from a
    /// loaded snapshot. Without this, each assignment would fire `didSet`
    /// which schedules a save of the just-loaded state — and if the user
    /// had a pending edit that hadn't yet flushed to disk, that pending
    /// snapshot gets overwritten and the edit is silently lost.
    private var isApplyingDiskState: Bool = false
    @Published var activeSelection: Selection = .list("inbox")
    @Published var activeContextFilter: TaskContext?
    @Published var showDone: Bool = false
    @Published var showDeferred: Bool = false
    /// "next" mode: hide everything but the first task of the current view.
    /// Used by the header toggle's third state for focus-mode work.
    @Published var limitToFirst: Bool = false
    @Published var selectedTaskId: String?

    /// Id of the task whose title is being inline-edited. `nil` when no row is
    /// in edit mode. The `e` key sets this; row commit clears it.
    @Published var editingTaskId: String?

    /// Backing storage for `collapsedIds` — extensions can't add stored
    /// properties, so Nesting.swift reaches through this.
    @Published var _collapsedIds: Set<String> = []

    /// Persistence handle. Tests can inject an in-memory no-op by passing `nil`.
    private let persistence: TaskStorePersistence?

    /// Snapshot-based undo stack. Each entry is the `(tasks, selection)` pair
    /// that was current *before* a mutation. `undo()` pops the most recent.
    private struct Snapshot {
        let tasks: [TaskItem]
        let selectedTaskId: String?
    }
    private var history: [Snapshot] = []
    private let historyLimit = 100

    init(persistence: TaskStorePersistence? = TaskStorePersistence.shared) {
        self.persistence = persistence
        if let snapshot = persistence?.load(), !snapshot.tasks.isEmpty || !snapshot.projects.isEmpty {
            self.projects = snapshot.projects
            self.tasks = snapshot.tasks.map { t in
                var copy = t
                if copy.pos == nil { copy.pos = copy.created }
                return copy
            }
        } else {
            self.projects = Self.seedProjects
            self.tasks = Self.seedTasks()
            // Persist the seed so the on-disk doc starts with sensible content.
            persistence?.saveNow(.init(tasks: self.tasks, projects: self.projects))
        }

        // When another device writes the shared .automerge file, refresh.
        persistence?.onExternalChange = { [weak self] in
            self?.refreshFromDisk()
        }
    }

    /// Called after an external merge. Reload the in-memory state from the
    /// now-merged doc without touching the undo stack.
    private func refreshFromDisk() {
        guard let snap = persistence?.load() else { return }
        let selected = selectedTaskId
        isApplyingDiskState = true
        self.projects = snap.projects
        self.tasks = snap.tasks.map { t in
            var copy = t
            if copy.pos == nil { copy.pos = copy.created }
            return copy
        }
        isApplyingDiskState = false
        // Preserve selection if the task still exists.
        if let sid = selected, !tasks.contains(where: { $0.id == sid }) {
            self.selectedTaskId = nil
        }
    }

    /// In-memory-only store for tests. Pre-populated with demo tasks so
    /// navigation/search/nesting tests have a realistic multi-project
    /// dataset without every suite having to seed manually. Tests that
    /// want an empty store can set `store.tasks = []` after construction.
    static func ephemeral() -> TaskStore {
        let s = TaskStore(persistence: nil)
        s.tasks = demoTasks()
        return s
    }

    // Explicit-delete buffers. Populated by `delete(_:)` /
    // `deleteProject(id:)` and drained on the next save so the on-disk
    // Automerge doc records a real tombstone for the key.
    //
    // `pendingTaskDeletes` is keyed by taskId → listId because the
    // persistence layer needs to know WHICH doc (main vs a shared
    // project's file) should receive the tombstone. We capture listId
    // at delete-time since the task is about to be removed from
    // `tasks` and we'd lose that mapping otherwise.
    private var pendingTaskDeletes: [String: String] = [:]
    private var pendingProjectDeletes: Set<String> = []

    private func scheduleSave() {
        guard let persistence else { return }
        let taskDeletes = pendingTaskDeletes
        let projectDeletes = pendingProjectDeletes
        pendingTaskDeletes.removeAll()
        pendingProjectDeletes.removeAll()
        persistence.scheduleSave(
            .init(tasks: tasks, projects: projects),
            deletedTaskIds: taskDeletes,
            deletedProjectIds: projectDeletes
        )
    }

    /// Record that a task id was explicitly deleted, so the next save will
    /// tombstone it in the right Automerge doc. Looks up the task's
    /// current listId so persistence can route to main vs a shared file.
    func markTaskDeleted(_ id: String) {
        let listId = tasks.first(where: { $0.id == id })?.list ?? ""
        pendingTaskDeletes[id] = listId
    }

    /// Record that a project id was explicitly deleted.
    func markProjectDeleted(_ id: String) { pendingProjectDeletes.insert(id) }

    // MARK: - Undo

    /// Capture the current state before a mutation. Call this at the top of
    /// every mutation that should be undo-able.
    func snapshot() {
        history.append(Snapshot(tasks: tasks, selectedTaskId: selectedTaskId))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    /// Returns true if a previous state was restored. No-op when the stack is empty.
    @discardableResult
    func undo() -> Bool {
        guard let prev = history.popLast() else { return false }
        tasks = prev.tasks
        selectedTaskId = prev.selectedTaskId
        return true
    }

    /// Depth of the undo stack. Exposed for tests.
    var undoDepth: Int { history.count }

    // MARK: - Lists

    var allLists: [ProjectItem] {
        [inboxProject] + projects
    }

    var inboxProject: ProjectItem {
        ProjectItem(id: "inbox", name: "inbox", icon: "tray", accent: Theme.orange, isInbox: true)
    }

    func project(id: String) -> ProjectItem? {
        if id == "inbox" { return inboxProject }
        return projects.first(where: { $0.id == id })
    }

    // MARK: - List mode (header toggle)

    /// Header toggle cycles through: todo → next → all → todo.
    /// - `todo`: open, non-deferred tasks (default).
    /// - `next`: only the single top-of-list task — focus mode.
    /// - `all`: everything, including completed and deferred.
    func cycleListMode() {
        if limitToFirst {
            // next → all
            limitToFirst = false
            showDone = true
            showDeferred = true
        } else if showDone && showDeferred {
            // all → todo
            showDone = false
            showDeferred = false
            limitToFirst = false
        } else {
            // todo → next
            limitToFirst = true
            showDone = false
            showDeferred = false
        }
    }

    var listModeLabel: String {
        if limitToFirst { return "next" }
        if showDone && showDeferred { return "all" }
        return "todo"
    }

    /// True when the list is in its quiet default state (hides done +
    /// deferred, shows full list). Used by views to dim the toggle chip.
    var listModeIsDefault: Bool {
        !limitToFirst && !showDone && !showDeferred
    }

    // MARK: - Derived

    /// Tasks for the currently selected scope, honoring show-done/deferred
    /// and "next" (first-only) toggles.
    var viewTasks: [TaskItem] {
        let base = filtered(by: activeSelection, ctxFilter: activeContextFilter)
        let sorted = base
            .filter { showDone || !$0.isDone }
            .filter { showDeferred || !$0.isDeferred }
            .sorted(by: Self.sortTasks)
        if limitToFirst {
            return Array(sorted.prefix(1))
        }
        return sorted
    }

    func filtered(by selection: Selection, ctxFilter: TaskContext? = nil) -> [TaskItem] {
        switch selection {
        case .list(let listId):
            if let ctx = ctxFilter {
                return tasks.filter { $0.ctx == ctx }
            }
            return tasks.filter { $0.list == listId }
        case .context(let ctx):
            return tasks.filter { $0.ctx == ctx }
        }
    }

    func countOpen(in listId: String) -> Int {
        tasks.filter { $0.list == listId && !$0.isDone && !$0.isDeferred }.count
    }

    func countOpen(ctx: TaskContext) -> Int {
        tasks.filter { $0.ctx == ctx && !$0.isDone && !$0.isDeferred }.count
    }

    func countDueToday(in listId: String) -> Int {
        tasks.filter { $0.list == listId && !$0.isDone && $0.due == .today }.count
    }

    func countDeferred(in listId: String) -> Int {
        tasks.filter { $0.list == listId && !$0.isDone && $0.isDeferred }.count
    }

    // MARK: - Mutations

    func add(raw: String) {
        let listId: String
        switch activeSelection {
        case .list(let id): listId = id
        case .context: listId = "inbox"
        }
        add(raw: raw, list: listId)
    }

    /// Add a task to a specific list, ignoring the current `activeSelection`.
    /// The menu bar quick-add uses this so captures always land in the inbox
    /// regardless of which project the main window is showing.
    @discardableResult
    func add(raw: String, list listId: String) -> String? {
        let parsed = QuickAddParser.parse(raw)
        let title = parsed.title.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : parsed.title
        guard !title.isEmpty else { return nil }
        snapshot()
        // New tasks get pos = now, which is the largest timestamp in the
        // group — sortTasks_ sorts ASC by pos, so they land at the bottom.
        let now = Date()
        let task = TaskItem(
            list: listId,
            title: title,
            ctx: parsed.ctx,
            note: parsed.note,
            created: now,
            due: parsed.due,
            pos: now
        )
        tasks.append(task)
        return task.id
    }

    func toggleDone(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        if tasks[idx].doneAt != nil {
            tasks[idx].doneAt = nil
        } else {
            tasks[idx].doneAt = Date()
        }
        stamp(&tasks[idx])
    }

    func delete(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        snapshot()
        markTaskDeleted(id)
        tasks.removeAll { $0.id == id }
        if selectedTaskId == id { selectedTaskId = nil }
    }

    func defer_(_ id: String, until date: Date) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].deferUntil = date
        stamp(&tasks[idx])
    }

    func clearDefer(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].deferUntil = nil
        stamp(&tasks[idx])
    }

    func move(_ id: String, toList listId: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].list = listId
        stamp(&tasks[idx])
    }

    func setContext(_ id: String, ctx: TaskContext?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].ctx = ctx
        stamp(&tasks[idx])
    }

    func setDue(_ id: String, due: DueBucket?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].due = due
        stamp(&tasks[idx])
    }

    func setTitle(_ id: String, title: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].title != title else { return }
        snapshot()
        tasks[idx].title = title
        stamp(&tasks[idx])
    }

    func setNote(_ id: String, note: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].note != note else { return }
        snapshot()
        tasks[idx].note = note
        stamp(&tasks[idx])
    }

    /// Reserved for future sync-ready fields. Currently a no-op since
    /// Automerge tracks causality implicitly via the doc's actor IDs.
    private func stamp(_ task: inout TaskItem) { _ = task }

    /// Returns the new project's id so callers can put it into edit mode
    /// immediately after creation — the expected UX is "create empty +
    /// focus name field", not "create with placeholder name".
    @discardableResult
    func addProject(name: String = "", accent: Color = Theme.accent, icon: String = "folder") -> String {
        let id = "p_\(UUID().uuidString.prefix(8).lowercased())"
        projects.append(ProjectItem(id: id, name: name, icon: icon, accent: accent))
        return id
    }

    func renameProject(id: String, to name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = name
    }

    func deleteProject(id: String) {
        // Tombstone the project AND every task that lived in it, so device B
        // doesn't resurrect a dangling orphan on the next merge.
        let orphans = tasks.filter { $0.list == id }.map(\.id)
        markProjectDeleted(id)
        for tid in orphans { markTaskDeleted(tid) }
        projects.removeAll { $0.id == id }
        tasks.removeAll { $0.list == id }
        if case .list(let sel) = activeSelection, sel == id {
            activeSelection = .list("inbox")
        }
    }

    // MARK: - Sharing

    enum ShareError: Error, LocalizedError, Equatable {
        case projectNotFound
        case inboxNotShareable
        case alreadyShared
        case noSyncFolder
        case invalidLink(String)
        case keyPersistenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .projectNotFound: return "Project not found."
            case .inboxNotShareable: return "The inbox can't be shared."
            case .alreadyShared: return "This project is already shared."
            case .noSyncFolder: return "Pick a sync folder in Settings before sharing."
            case .invalidLink(let why): return "That share link isn't valid: \(why)"
            case .keyPersistenceFailed(let why): return "Couldn't save the share key: \(why)"
            }
        }
    }

    /// Promote a local project to a shared (encrypted, multi-user)
    /// project. Generates a fresh symmetric key, moves the project's
    /// tasks into a separate encrypted file in the sync folder, and
    /// leaves the project record in the main doc with `isShared = true`.
    ///
    /// Returns the share-link URL the user can send to collaborators.
    /// The key is already in the key store at this point; the link
    /// carries the key in its fragment so collaborators can join.
    ///
    /// Phase 3b scope: this only handles the *promotion* path. Ongoing
    /// read/write routing to the shared file comes in Phase 3c; until
    /// then, a promoted project's tasks vanish from the main TaskStore
    /// snapshot until they're re-loaded through that path.
    @discardableResult
    func promoteToShared(_ projectId: String, manager: SharedProjectManager) throws -> URL {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw ShareError.projectNotFound
        }
        guard !project.isInbox else { throw ShareError.inboxNotShareable }
        guard !project.isShared else { throw ShareError.alreadyShared }

        let projectTasks = tasks.filter { $0.list == projectId }
        let created = try manager.createShared(project: project, tasks: projectTasks)

        // Local main-doc cleanup: flag the project shared, tombstone
        // its tasks so the main doc no longer carries them. Snapshot
        // first so the whole promotion is one undo unit.
        snapshot()
        if let idx = projects.firstIndex(where: { $0.id == projectId }) {
            projects[idx].isShared = true
        }
        for t in projectTasks { markTaskDeleted(t.id) }
        tasks.removeAll { $0.list == projectId }

        return ShareLink.encode(projectId: projectId, key: created.key)
    }

    /// Accept an incoming `todarchy://share/...` link: persist the key
    /// locally, then add a stub project to the main doc flagged
    /// `isShared = true`. The persistence layer's `refreshSharedStores`
    /// sees the stub on the next tick and opens a `PerProjectStore`
    /// against the encrypted file, which sync has (or will) deliver.
    ///
    /// Idempotent: if we've already joined this project (key in store +
    /// project in our list), this is a no-op success.
    @discardableResult
    func acceptShareLink(_ url: URL, manager: SharedProjectManager) throws -> ProjectItem {
        let payload: ShareLink.Payload
        switch ShareLink.decode(url) {
        case .success(let p): payload = p
        case .failure(let e): throw ShareError.invalidLink(e.localizedDescription)
        }
        return try acceptPayload(payload, manager: manager)
    }

    /// Internal path used by both `acceptShareLink` and any caller that
    /// already has a decoded payload (e.g. pasted text UIs).
    @discardableResult
    func acceptPayload(_ payload: ShareLink.Payload,
                       manager: SharedProjectManager) throws -> ProjectItem {
        // Persist key + prepare a store handle. The file itself might
        // not be on disk yet — Dropbox may still be downloading — but
        // accept() doesn't require it.
        let store: PerProjectStore
        do {
            store = try manager.accept(payload: payload)
        } catch {
            throw ShareError.keyPersistenceFailed(error.localizedDescription)
        }

        // If the encrypted file already landed, pull the real project
        // metadata from it. Otherwise stub a placeholder; the shared
        // file's own ProjectItem will overwrite ours once it arrives
        // (Persistence.load prefers the shared-file copy over the
        // main-doc stub).
        if let existingIdx = projects.firstIndex(where: { $0.id == payload.projectId }) {
            // Already in our list — make sure the shared flag is set.
            if !projects[existingIdx].isShared {
                projects[existingIdx].isShared = true
            }
            return projects[existingIdx]
        }

        let project: ProjectItem
        if let snap = try? store.readSnapshot() {
            var p = snap.project
            p.isShared = true
            project = p
        } else {
            project = ProjectItem(
                id: payload.projectId,
                name: "shared project",
                icon: "person.2.fill",
                accent: Theme.accent2,
                isShared: true
            )
        }
        projects.append(project)
        return project
    }

    // MARK: - Sort

    /// Sort by done-state, due-bucket, and `pos` ASC (oldest-first within a
    /// group). New tasks land at the bottom of their group — work top-down,
    /// check off, move on. Cross-device reorders come through via `pos`
    /// mutations rather than array swaps — the Automerge list order isn't
    /// authoritative.
    static func sortTasks_(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.isDone != b.isDone { return !a.isDone && b.isDone }
        let ar = a.due?.sortOrder ?? 3
        let br = b.due?.sortOrder ?? 3
        if ar != br { return ar < br }
        return a.sortPos < b.sortPos
    }

    private static func sortTasks(_ a: TaskItem, _ b: TaskItem) -> Bool {
        sortTasks_(a, b)
    }

    // MARK: - Seed

    static let seedProjects: [ProjectItem] = [
        .init(id: "p_work", name: "work", icon: "briefcase.fill", accent: Theme.accent),
        .init(id: "p_home", name: "home", icon: "house.fill", accent: Theme.cyan),
        .init(id: "p_wedding", name: "wedding planning", icon: "sparkles", accent: Theme.accent2),
    ]

    /// Fresh installs start with an empty task list. New users see the
    /// empty-state hint and type their first task instead of greeting a
    /// pile of fake examples. Seed projects are still created so there's
    /// somewhere to file tasks beyond the inbox.
    static func seedTasks() -> [TaskItem] { [] }

    /// Pre-populated fake tasks used by navigation tests and by the
    /// preview/demo harness. NOT inserted on fresh install — call
    /// explicitly in tests that need a non-empty store.
    static func demoTasks() -> [TaskItem] {
        func uuid(_ suffix: UInt32) -> String {
            String(format: "00000000-0000-0000-0000-%012x", suffix)
        }
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func ahead(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

        let seeds: [TaskItem] = [
            TaskItem(id: uuid(0x0001), list: "inbox", title: "figure out btrfs snapshots for /home",
                     ctx: .mac, note: "limine + snapper. hyprland wiki link in bookmarks.",
                     created: ago(2)),
            TaskItem(id: uuid(0x0002), list: "inbox", title: "reply to matteo re. keyboard layout swap",
                     ctx: .work, created: ago(1)),
            TaskItem(id: uuid(0x0003), list: "inbox", title: "pick up pasta + tomatoes",
                     ctx: .errands, created: ago(0.5)),
            TaskItem(id: uuid(0x1001), list: "p_work", title: "draft Q2 planning doc",
                     ctx: .work, note: "3 themes. link: notion://planning-q2",
                     created: ago(26), due: .today),
            TaskItem(id: uuid(0x1002), list: "p_work", title: "review pull requests (3)",
                     ctx: .work, note: "#412 #418 #421",
                     created: ago(9), due: .tomorrow),
            TaskItem(id: uuid(0x1003), list: "p_work", title: "1:1 prep with rohan",
                     ctx: .work, note: "growth areas · q2 goals",
                     created: ago(14), due: .thisWeek),
            TaskItem(id: uuid(0x1004), list: "p_work", title: "update team OKRs in notion",
                     ctx: .work, created: ago(48), deferUntil: ahead(48)),
            TaskItem(id: uuid(0x1005), list: "p_work", title: "kickoff infra migration",
                     ctx: .work, created: ago(72), doneAt: ago(24)),
            TaskItem(id: uuid(0x2001), list: "p_home", title: "rewrite hyprland keybinds for tiling sanity",
                     ctx: .mac, note: "super+h/j/k/l for focus.\nbind = SUPER, h, movefocus, l",
                     created: ago(20), due: .today),
            TaskItem(id: uuid(0x2002), list: "p_home", title: "20min run + stretch",
                     ctx: .home, created: ago(5), due: .today),
            TaskItem(id: uuid(0x2003), list: "p_home", title: "call dentist, move to thursday",
                     ctx: .phone, created: ago(50), due: .thisWeek),
            TaskItem(id: uuid(0x2004), list: "p_home", title: "build mechanical keyboard from kit",
                     ctx: .home, note: "lily58 // choc low-pro",
                     created: ago(240)),
            TaskItem(id: uuid(0x2005), list: "p_home", title: "follow up with the landlord re. lease",
                     ctx: .phone, created: ago(48), deferUntil: ahead(20)),
            TaskItem(id: uuid(0x2006), list: "p_home", title: "migrate dotfiles to chezmoi",
                     ctx: .mac, created: ago(48), doneAt: ago(20)),
            TaskItem(id: uuid(0x3001), list: "p_wedding", title: "finalize guest list (round 2)",
                     ctx: .home, note: "target: 110 ± 10",
                     created: ago(30), due: .thisWeek),
            TaskItem(id: uuid(0x3002), list: "p_wedding", title: "tasting appointment — saturday 2pm",
                     ctx: .errands, note: "bring notes from rehearsal",
                     created: ago(48), due: .thisWeek),
            TaskItem(id: uuid(0x3003), list: "p_wedding", title: "send save-the-dates",
                     ctx: .errands, created: ago(96), doneAt: ago(48)),
            TaskItem(id: uuid(0x3004), list: "p_wedding", title: "book florist consultation",
                     ctx: .phone, created: ago(144), deferUntil: ahead(72)),
            TaskItem(id: uuid(0x3005), list: "p_wedding", title: "first dance song shortlist",
                     ctx: .read, created: ago(168)),
            TaskItem(id: uuid(0x3006), list: "p_wedding", title: "research honeymoon destinations",
                     ctx: .read, note: "lisbon / tokyo / crete",
                     created: ago(288)),
        ]
        return seeds.map { t in
            var copy = t
            copy.pos = copy.created
            return copy
        }
    }
}

enum TimeAgo {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 30 { return "\(d)d" }
        return "\(d / 30)mo"
    }

    static func deferUntil(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let t = f.string(from: date)
        if cal.isDateInToday(date) { return "today \(t)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(t)" }
        let days = cal.dateComponents([.day], from: now, to: date).day ?? 0
        if days > 1 && days < 7 {
            let wf = DateFormatter()
            wf.dateFormat = "EEE"
            return "\(wf.string(from: date).lowercased()) \(t)"
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(df.string(from: date).lowercased()) \(t)"
    }
}
