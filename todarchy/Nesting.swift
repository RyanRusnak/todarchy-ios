import Foundation
import Combine

/// Row in the visible tree, computed from `tasks` + collapse state.
struct TaskTreeRow: Identifiable, Equatable {
    let task: TaskItem
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    var id: String { task.id }
}

extension TaskStore {
    /// Ids of parent tasks whose subtrees are currently collapsed.
    /// Separated from the model so we don't bloat TaskItem with UI state.
    var collapsedIds: Set<String> {
        get { _collapsedIds }
        set { _collapsedIds = newValue }
    }

    /// Visible tree for the current selection/filter, flattened via DFS so
    /// SwiftUI can render it in a plain `LazyVStack`.
    var viewTree: [TaskTreeRow] {
        let base = filtered(by: activeSelection, ctxFilter: activeContextFilter)
            .filter { showDone || !$0.isDone }
            .filter { showDeferred || !$0.isDeferred }

        // Build `children` map + roots in the order the underlying `tasks`
        // array defines (stable sort inside each sort group).
        var visibleSet = Set(base.map(\.id))
        var byParent: [String?: [TaskItem]] = [:]
        // Walk in array order so relative order is preserved.
        for t in tasks where visibleSet.contains(t.id) {
            // Promote orphans whose parent is missing from the visible set to
            // roots — otherwise they'd vanish.
            let effectiveParent: String? = {
                guard let p = t.parent else { return nil }
                return visibleSet.contains(p) ? p : nil
            }()
            byParent[effectiveParent, default: []].append(t)
        }
        _ = visibleSet  // silence warning

        // Sort each bucket by (isDone, due) to match viewTasks semantics.
        for k in byParent.keys {
            byParent[k]?.sort(by: Self.sortTasks_)
        }

        var out: [TaskTreeRow] = []
        func visit(_ t: TaskItem, depth: Int) {
            let kids = byParent[t.id] ?? []
            let collapsed = _collapsedIds.contains(t.id)
            out.append(TaskTreeRow(
                task: t,
                depth: depth,
                hasChildren: !kids.isEmpty,
                isCollapsed: collapsed
            ))
            if !collapsed {
                for k in kids { visit(k, depth: depth + 1) }
            }
        }
        for root in byParent[nil] ?? [] {
            visit(root, depth: 0)
        }
        return out
    }

    // MARK: - Mutations

    /// Indent the selected task: makes it a child of the visible task above it
    /// in the current tree. Requires a preceding sibling at the same depth.
    @discardableResult
    func indentSelected() -> Bool {
        guard let sid = selectedTaskId else { return false }
        let rows = viewTree
        guard let ri = rows.firstIndex(where: { $0.id == sid }), ri > 0 else { return false }
        let self_ = rows[ri]
        // Walk upward to find a task at the same depth (a preceding sibling).
        var ni = ri - 1
        while ni >= 0 && rows[ni].depth > self_.depth { ni -= 1 }
        guard ni >= 0, rows[ni].depth == self_.depth else { return false }
        guard let idx = tasks.firstIndex(where: { $0.id == sid }) else { return false }
        snapshot()
        tasks[idx].parent = rows[ni].id
        stampAt(idx)
        _collapsedIds.remove(rows[ni].id)   // auto-expand the new parent
        return true
    }

    /// Outdent the selected task: makes it a sibling of its current parent.
    @discardableResult
    func outdentSelected() -> Bool {
        guard let sid = selectedTaskId,
              let idx = tasks.firstIndex(where: { $0.id == sid }),
              let parentId = tasks[idx].parent else { return false }
        guard let parentIdx = tasks.firstIndex(where: { $0.id == parentId }) else { return false }
        snapshot()
        tasks[idx].parent = tasks[parentIdx].parent
        stampAt(idx)
        return true
    }

    /// Toggle whether the selected task's subtree is collapsed. No-op for leaves.
    @discardableResult
    func toggleCollapseSelected() -> Bool {
        guard let sid = selectedTaskId else { return false }
        let hasChildren = tasks.contains { $0.parent == sid }
        guard hasChildren else { return false }
        if _collapsedIds.contains(sid) { _collapsedIds.remove(sid) }
        else { _collapsedIds.insert(sid) }
        // @Published var tasks didSet won't fire from Set mutation, so bump
        // something else to force a view refresh.
        objectWillChange.send()
        return true
    }

    /// Cascade delete a task and its descendants.
    @discardableResult
    func deleteSubtree(_ id: String) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        snapshot()
        var victims: Set<String> = [id]
        var frontier: Set<String> = [id]
        while !frontier.isEmpty {
            let kids = tasks.filter { p in
                guard let parent = p.parent else { return false }
                return frontier.contains(parent)
            }.map(\.id)
            frontier = Set(kids).subtracting(victims)
            victims.formUnion(frontier)
        }
        for v in victims { markTaskDeleted(v) }
        tasks.removeAll { victims.contains($0.id) }
        if let sid = selectedTaskId, victims.contains(sid) { selectedTaskId = nil }
        return true
    }

    /// Reserved — previously stamped sync-only fields, now a no-op.
    private func stampAt(_ idx: Int) { _ = idx }
}

// Storage for collapsedIds. Swift doesn't let extensions add stored props, so
// we tunnel through an associated-object-free indirection: a tiny internal var
// in Store.swift exposes a backing Set for this module.
