import Foundation
import Combine
import SwiftUI

final class TaskStore: ObservableObject {
    @Published var tasks: [TaskItem] { didSet { if !isApplyingDiskState { scheduleSave() } } }
    @Published var projects: [ProjectItem] { didSet { if !isApplyingDiskState { scheduleSave() } } }

    /// User-managed context list. Replaces the static `TaskContext.allCases`
    /// reads at every UI surface. Seeded with the built-ins on first launch
    /// and grown automatically when the parser encounters a new `@token`.
    @Published var contexts: [TaskContext] { didSet { if !isApplyingDiskState { scheduleSave() } } }

    /// Contexts the user deliberately removed. `adoptContextsFromTasks`
    /// skips these, so a removal sticks even while tasks still reference
    /// the context. Synced like `contexts`, so removing a context on one
    /// machine doesn't get undone by adoption on another.
    @Published var retiredContexts: [TaskContext] { didSet { if !isApplyingDiskState { scheduleSave() } } }

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
            // Snapshots from before the contexts list was persisted decode
            // with `nil`; treat that as "use the built-in seed" rather than
            // wiping the user's chips on launch.
            let loaded = snapshot.contexts ?? []
            self.contexts = loaded.isEmpty ? TaskContext.allCases : loaded
            self.retiredContexts = snapshot.retiredContexts ?? []
        } else {
            self.projects = Self.seedProjects
            self.tasks = Self.seedTasks()
            self.contexts = TaskContext.allCases
            self.retiredContexts = []
            // Persist the seed so the on-disk doc starts with sensible content.
            persistence?.saveNow(.init(
                tasks: self.tasks,
                projects: self.projects,
                contexts: self.contexts
            ))
        }
        // Tasks authored elsewhere (the Linux/web app, the MCP server,
        // another device) arrive with `ctx` values this machine has never
        // seen. Fold them in so the chip list is the same everywhere.
        adoptContextsFromTasks()
        dedupeContexts()

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
        let loadedTasks = snap.tasks.map { t -> TaskItem in
            var copy = t
            if copy.pos == nil { copy.pos = copy.created }
            return copy
        }
        // Every one of these is `@Published`, so an assignment fires
        // `objectWillChange` and makes SwiftUI re-diff the whole list.
        // Comparing first is what keeps the common caller cheap: `flushNow`
        // notifies unconditionally after a debounced save, and the snapshot
        // it just wrote is the one this store handed it — so on a local
        // edit all four compare equal and the reload publishes nothing.
        isApplyingDiskState = true
        if loadedTasks != tasks { self.tasks = loadedTasks }
        if snap.projects != projects { self.projects = snap.projects }
        // External writers (sync) may have added/removed contexts; pick up
        // their list. Fall back to the in-memory list rather than wiping
        // when the doc is from before the field existed.
        if let loaded = snap.contexts, !loaded.isEmpty, loaded != contexts {
            self.contexts = loaded
        }
        if let retired = snap.retiredContexts, retired != retiredContexts {
            self.retiredContexts = retired
        }
        isApplyingDiskState = false
        // Runs with `isApplyingDiskState` already cleared: anything adopted
        // here is a genuine local change that has to be saved back so the
        // rest of the fleet converges on the same list. Both bail out
        // without touching `contexts` when there's nothing to do.
        adoptContextsFromTasks()
        dedupeContexts()
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

    // MARK: - Context mutations

    /// Contexts ordered for quick-add pickers: most-used first, so the
    /// contexts you actually reach for float to the front and unused built-in
    /// defaults sink to the end (where they stop crowding out the ones that
    /// matter). Score is the number of tasks carrying each context; ties break
    /// on the recency of the most recent such task, then on the context's
    /// existing position (so the ordering is stable and defaults keep their
    /// relative order among themselves). The persisted `contexts` array and
    /// the sidebar/editor orderings are untouched — this is presentation-only.
    var contextsByUsage: [TaskContext] {
        var count: [TaskContext: Int] = [:]
        var recent: [TaskContext: Date] = [:]
        for t in tasks {
            guard let c = t.ctx else { continue }
            count[c, default: 0] += 1
            let stamp = t.sortPos
            if stamp > (recent[c] ?? .distantPast) { recent[c] = stamp }
        }
        return contexts.enumerated().sorted { a, b in
            let ca = count[a.element] ?? 0, cb = count[b.element] ?? 0
            if ca != cb { return ca > cb }
            switch (recent[a.element], recent[b.element]) {
            case let (ra?, rb?) where ra != rb: return ra > rb
            case (.some, .none): return true      // used sorts before never-used
            case (.none, .some): return false
            default: return a.offset < b.offset   // stable fallback
            }
        }.map { $0.element }
    }

    /// Add a context label. Idempotent: re-adding an existing context (case-
    /// insensitive after normalization) is a no-op. Used by both the editor
    /// sheet and `add(raw:list:)` for auto-discovery from `@token` parsing.
    @discardableResult
    func addContext(_ raw: String) -> TaskContext? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let ctx = TaskContext(rawValue: trimmed)
        // The TaskContext init enforces a single leading `@`, so contexts
        // with just punctuation collapse to "@" — refuse those.
        guard ctx.rawValue.count > 1 else { return nil }
        // Adding back a previously removed context un-retires it, so
        // adoption stops suppressing it.
        if retiredContexts.contains(ctx) {
            retiredContexts.removeAll { $0 == ctx }
        }
        if contexts.contains(ctx) { return ctx }
        snapshot()
        contexts.append(ctx)
        return ctx
    }

    /// Fold every `ctx` referenced by a task into `contexts`.
    ///
    /// Local quick-add already registers the `@token` it parses, but tasks
    /// that arrive over sync don't go through that path — a task created
    /// on the Linux app, the web app, or via the MCP server carried a
    /// context the Mac had never heard of, so the sidebar and pickers
    /// disagreed machine to machine. Adoption makes the list a function of
    /// the doc rather than of where a task happened to be typed.
    ///
    /// Deliberately removed contexts (`retiredContexts`) are skipped, so
    /// this never resurrects one the user just deleted. Discovered
    /// contexts are appended in sorted order so two machines adopting the
    /// same batch end up with the same list instead of fighting over it.
    @discardableResult
    func adoptContextsFromTasks() -> [TaskContext] {
        let known = Set(contexts)
        let retired = Set(retiredContexts)
        var discovered: Set<TaskContext> = []
        for t in tasks {
            guard let c = t.ctx, !known.contains(c), !retired.contains(c) else { continue }
            discovered.insert(c)
        }
        guard !discovered.isEmpty else { return [] }
        let added = discovered.sorted { $0.rawValue < $1.rawValue }
        contexts.append(contentsOf: added)
        return added
    }

    /// Collapse repeated entries, keeping the first occurrence.
    ///
    /// Two devices adopting the same unseen context concurrently insert it
    /// into the Automerge array as distinct elements, so a merged doc can
    /// carry the same context twice. `TaskContext.id` is the rawValue, so
    /// duplicates also break ForEach identity — fold them on every load.
    func dedupeContexts() {
        guard contexts.count != Set(contexts.map(\.rawValue)).count else { return }
        var seen = Set<String>()
        contexts.removeAll { !seen.insert($0.rawValue).inserted }
    }

    /// Remove a context. Tasks that reference it keep their `ctx` value —
    /// the row UI still renders the chip from the raw string, so the
    /// information isn't lost. The user can clean up via the inspector
    /// or re-add the context to bring it back.
    func removeContext(_ ctx: TaskContext) {
        guard contexts.contains(ctx) else { return }
        snapshot()
        contexts.removeAll { $0 == ctx }
        // Record the removal so `adoptContextsFromTasks` doesn't hand it
        // straight back — here or on any other machine.
        if !retiredContexts.contains(ctx) { retiredContexts.append(ctx) }
        if activeContextFilter == ctx { activeContextFilter = nil }
    }

    /// Rename `from` to `to` — both in the contexts list and on every task
    /// that points to `from`. Refuses to overwrite an existing context.
    @discardableResult
    func renameContext(from: TaskContext, to rawTo: String) -> Bool {
        let target = TaskContext(rawValue: rawTo)
        guard target.rawValue.count > 1 else { return false }
        if target == from { return true }
        if contexts.contains(target) { return false }
        snapshot()
        if retiredContexts.contains(target) {
            retiredContexts.removeAll { $0 == target }
        }
        if let idx = contexts.firstIndex(of: from) {
            contexts[idx] = target
        }
        for i in tasks.indices where tasks[i].ctx == from {
            tasks[i].ctx = target
        }
        if activeContextFilter == from { activeContextFilter = target }
        return true
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
    /// Task ids whose `doneAt` was explicitly cleared by the user (uncheck).
    /// Drained on the next save so the persistence layer tombstones the field.
    private var pendingDoneAtClears: Set<String> = []

    private func scheduleSave() {
        guard let persistence else { return }
        let taskDeletes = pendingTaskDeletes
        let projectDeletes = pendingProjectDeletes
        let doneAtClears = pendingDoneAtClears
        pendingTaskDeletes.removeAll()
        pendingProjectDeletes.removeAll()
        pendingDoneAtClears.removeAll()
        persistence.scheduleSave(
            .init(tasks: tasks, projects: projects,
                  contexts: contexts, retiredContexts: retiredContexts),
            deletedTaskIds: taskDeletes,
            deletedProjectIds: projectDeletes,
            doneAtClears: doneAtClears
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
        // `.today` covers overdue too (DueDate.bucket collapses past-due into
        // today), so this badge counts everything actionable today or earlier.
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
        // Auto-register an unfamiliar context so it appears in the sidebar
        // and pickers. Built-ins are already in `contexts`; new tokens get
        // appended.
        if let parsedCtx = parsed.ctx, !contexts.contains(parsedCtx) {
            contexts.append(parsedCtx)
        }
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
            pendingDoneAtClears.insert(id)
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
        // Resolve the picked bucket to an absolute date at set-time, so the
        // label rolls over as days pass (a task set to "tomorrow" becomes
        // "today" the next day). `nil` clears the due date.
        tasks[idx].dueDate = DueDate.resolve(due)
        stamp(&tasks[idx])
    }

    /// Set an explicit due date (used by tests and any future date-picker UI).
    func setDueDate(_ id: String, date: Date?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        tasks[idx].dueDate = date
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

    /// Append a comment to a task. Author defaults to the user-set
    /// display name from `UserDefaults` (see `CommentAuthor.current`).
    /// Trimmed and whitespace-only inputs are rejected.
    @discardableResult
    func addComment(taskId: String, text: String, author: String? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        snapshot()
        let comment = Comment(
            author: author ?? CommentAuthor.current,
            text: trimmed
        )
        tasks[idx].comments.append(comment)
        return comment.id
    }

    /// Remove a comment from a task by id. Comments are otherwise
    /// append-only; the UI only offers this for comments the current
    /// device authored (`author == CommentAuthor.current`). Returns true
    /// if a matching comment was found and removed.
    @discardableResult
    func deleteComment(taskId: String, commentId: String) -> Bool {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return false }
        guard tasks[idx].comments.contains(where: { $0.id == commentId }) else { return false }
        snapshot()
        tasks[idx].comments.removeAll { $0.id == commentId }
        stamp(&tasks[idx])
        return true
    }

    /// Reserved for future sync-ready fields. Currently a no-op since
    /// Automerge tracks causality implicitly via the doc's actor IDs.
    private func stamp(_ task: inout TaskItem) { _ = task }

    /// Returns the new project's id so callers can put it into edit mode
    /// immediately after creation — the expected UX is "create empty +
    /// focus name field", not "create with placeholder name".
    @discardableResult
    func addProject(name: String = "", accent: Color = Theme.accent, icon: String = "folder") -> String {
        let id = "p_\(UUID().uuidString.lowercased())"
        projects.append(ProjectItem(id: id, name: name, icon: icon, accent: accent))
        return id
    }

    func renameProject(id: String, to name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = name
    }

    /// Grant / revoke MCP (Claude) access for a project. Synced via
    /// the main doc so the toggle state shows up on every device.
    func setClaudeAccess(id: String, enabled: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        guard projects[idx].claudeAccess != enabled else { return }
        projects[idx].claudeAccess = enabled
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

    /// "Leave shared project" — drop a shared project locally without
    /// affecting collaborators.
    ///
    /// Differs from `deleteProject` in three ways:
    ///   1. We never tombstone the project's tasks. They live in the
    ///      encrypted envelope on the relay; tombstoning them here
    ///      would propagate via shared-store sync and delete them
    ///      for every peer.
    ///   2. We drop the local key + local encrypted file via
    ///      `SharedProjectManager.forgetLocally` so the bytes don't
    ///      stick around uselessly.
    ///   3. We unpublish the project's key from this user's
    ///      `shareKeys.cipher` (best-effort, requires the master key
    ///      to be unlocked) so the user's *other* devices also drop
    ///      the project on next sync. The project tombstone in main
    ///      doc takes care of the rest.
    ///
    /// Falls back to `deleteProject` for non-shared projects so the
    /// caller doesn't have to branch.
    @MainActor
    func leaveSharedProject(_ projectId: String, manager: SharedProjectManager) throws {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw ShareError.projectNotFound
        }
        guard project.isShared else {
            deleteProject(id: projectId)
            return
        }

        // Best-effort: remove the key from the user's main-doc
        // shareKeys map. If the user is locked, the key stays in
        // the map and any of their other devices will hang onto a
        // dangling key (harmless, just untidy).
        if let masterK = MasterKey.shared.currentKey {
            try? persistence?.unpublishShareKey(projectId: projectId, masterKey: masterK)
        }

        // Forget the local key + encrypted file.
        try manager.forgetLocally(projectId: projectId)

        // Tombstone the project record so the user's other devices
        // also drop it on next merge. Do NOT mark tasks deleted —
        // they belong to the shared envelope, which we're leaving
        // intact for peers.
        snapshot()
        markProjectDeleted(projectId)
        projects.removeAll { $0.id == projectId }
        tasks.removeAll { $0.list == projectId }
        if case .list(let sel) = activeSelection, sel == projectId {
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
        case passphraseRequired
        case conflictingInvitation

        var errorDescription: String? {
            switch self {
            case .conflictingInvitation: return "This invitation conflicts with a shared list already on this device. Ask the sender to create a new list and share that list instead."
            case .projectNotFound: return "Project not found."
            case .inboxNotShareable: return "The inbox can't be shared."
            case .alreadyShared: return "This project is already shared."
            case .noSyncFolder: return "Pick a sync folder in Settings before sharing."
            case .invalidLink(let why): return "That share link isn't valid: \(why)"
            case .keyPersistenceFailed(let why): return "Couldn't save the share key: \(why)"
            case .passphraseRequired: return "Set a sync passphrase in Settings before sharing — keys can't propagate to your other devices without it."
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
    /// The visible tasks stay in the union snapshot while persistence
    /// routes them to the shared file and removes the main-doc copies.
    @discardableResult
    @MainActor
    func promoteToShared(_ projectId: String, manager: SharedProjectManager) throws -> URL {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw ShareError.projectNotFound
        }
        guard !project.isInbox else { throw ShareError.inboxNotShareable }
        guard !project.isShared else { throw ShareError.alreadyShared }

        // Starter ids (even after a rename) are identical across accounts.
        // Give those lists and their deterministic demo tasks fresh identities
        // before publishing anything under a globally visible relay id.
        var sharedProject = project
        var projectTasks = tasks.filter { $0.list == projectId }
        if Self.seedProjects.contains(where: { $0.id == projectId }) {
            sharedProject.id = "p_\(UUID().uuidString.lowercased())"
            projectTasks = Self.reidentifiedTasks(projectTasks, listId: sharedProject.id)
        }
        let created = try manager.createShared(project: sharedProject, tasks: projectTasks)
        sharedProject.isShared = true
        if sharedProject.id != projectId {
            replaceLocalProject(projectId, with: sharedProject, tasks: projectTasks,
                                retireOldProject: true)
        }

        // Best-effort publish to the user's main doc so their other
        // devices auto-learn the key via main-doc sync. Skipped (not
        // a hard failure) when no passphrase is set up — sharing
        // still works locally, the user just has to open the link
        // on each of their devices manually. The Settings UI gates
        // sharing on passphrase setup to avoid surprising users.
        if let masterK = MasterKey.shared.currentKey {
            try? persistence?.publishShareKey(projectId: sharedProject.id,
                                              key: created.key,
                                              masterKey: masterK)
        }

        // Keep tasks visible in the union snapshot. Persistence moves their
        // storage to the shared doc and cleans up only the main-doc copies.
        // Routing ordinary task deletions here would tombstone the new shared
        // copies as soon as the promotion's debounced save runs.
        if let idx = projects.firstIndex(where: { $0.id == projectId }) {
            projects[idx].isShared = true
        }

        return ShareLink.encode(projectId: sharedProject.id, key: created.key)
    }

    /// Demo tasks also have identical ids across accounts. Preserve nesting
    /// when moving a colliding list so the union cannot deduplicate its tasks.
    private static func reidentifiedTasks(_ tasks: [TaskItem], listId: String) -> [TaskItem] {
        let ids = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, TaskItem.newID()) })
        return tasks.map { task in
            var copy = task
            copy.id = ids[task.id]!
            copy.list = listId
            copy.parent = task.parent.map { ids[$0] ?? $0 }
            return copy
        }
    }

    private func replaceLocalProject(_ oldId: String, with project: ProjectItem,
                                     tasks replacements: [TaskItem], retireOldProject: Bool) {
        // Publish one complete snapshot. Cleanup must target the private doc,
        // even if an invitation is about to register oldId as a shared store.
        isApplyingDiskState = true
        let oldTasks = tasks.filter { $0.list == oldId }
        for task in oldTasks { pendingTaskDeletes[task.id] = "" }
        if retireOldProject { markProjectDeleted(oldId) }
        if let index = projects.firstIndex(where: { $0.id == oldId }) {
            projects[index] = project
        }
        tasks.removeAll { $0.list == oldId }
        tasks.append(contentsOf: replacements)
        if activeSelection == .list(oldId) { activeSelection = .list(project.id) }
        if let selected = selectedTaskId,
           let index = oldTasks.firstIndex(where: { $0.id == selected }) {
            selectedTaskId = replacements[index].id
        }
        editingTaskId = nil
        // Old undo snapshots reference the retired ids and could restore
        // private tasks into the newly joined shared list.
        history.removeAll()
        isApplyingDiskState = false
        scheduleSave()
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
    @MainActor
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
    @MainActor
    func acceptPayload(_ payload: ShareLink.Payload,
                       manager: SharedProjectManager) throws -> ProjectItem {
        // A matching id alone does not establish that this is the same list.
        // Never overwrite a different shared list's key or publish its tasks
        // into an unrelated invitation's document.
        if let existing = projects.first(where: { $0.id == payload.projectId }),
           existing.isShared,
           let key = manager.keyStore.load(for: payload.projectId), key != payload.key {
            throw ShareError.conflictingInvitation
        }

        // Persist key + prepare a store handle. The file itself might
        // not be on disk yet — Dropbox may still be downloading — but
        // accept() doesn't require it.
        let store: PerProjectStore
        do {
            store = try manager.accept(payload: payload)
        } catch {
            throw ShareError.keyPersistenceFailed(error.localizedDescription)
        }

        // An older invitation can collide with a renamed starter list.
        // Preserve that private list separately before joining the sender's.
        if var local = projects.first(where: { $0.id == payload.projectId && !$0.isShared }) {
            local.id = "p_\(UUID().uuidString.lowercased())"
            let moved = Self.reidentifiedTasks(tasks.filter { $0.list == payload.projectId },
                                               listId: local.id)
            replaceLocalProject(payload.projectId, with: local, tasks: moved,
                                retireOldProject: false)
        }

        // Propagate the freshly-accepted key into the user's main
        // doc's shareKeys map (when a passphrase has been set up).
        // This is what lets their other devices pick up the new
        // shared list without re-opening the same link there.
        // If no master key is available yet, swallow silently — the
        // key still lives in the local keychain, so this device can
        // read the shared envelope; we just don't propagate to peers.
        if let masterK = MasterKey.shared.currentKey {
            try? persistence?.publishShareKey(projectId: payload.projectId,
                                              key: payload.key,
                                              masterKey: masterK)
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
        // Dated tasks sort before undated; among dated, the soonest (and
        // overdue, being earliest) come first. Sorting by the absolute date
        // rather than the coarse bucket keeps ordering stable as labels roll
        // over and orders same-bucket tasks by actual due date.
        switch (a.dueDate, b.dueDate) {
        case let (ad?, bd?) where ad != bd:
            return ad < bd
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return a.sortPos < b.sortPos
        }
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
