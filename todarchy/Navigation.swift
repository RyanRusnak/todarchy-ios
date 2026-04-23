import Foundation

// MARK: - Selection navigation for TaskStore

extension TaskStore {
    /// Move selection down one row. If nothing selected, selects the first row.
    /// No-op when the visible list is empty.
    func selectNext() {
        let list = viewTasks
        guard !list.isEmpty else { return }
        guard let current = selectedTaskId,
              let idx = list.firstIndex(where: { $0.id == current }) else {
            selectedTaskId = list.first?.id
            return
        }
        selectedTaskId = list[min(idx + 1, list.count - 1)].id
    }

    /// Move selection up one row. If nothing selected, selects the first row.
    /// No-op when the visible list is empty.
    func selectPrevious() {
        let list = viewTasks
        guard !list.isEmpty else { return }
        guard let current = selectedTaskId,
              let idx = list.firstIndex(where: { $0.id == current }) else {
            selectedTaskId = list.first?.id
            return
        }
        selectedTaskId = list[max(idx - 1, 0)].id
    }

    func selectFirst() { selectedTaskId = viewTasks.first?.id }
    func selectLast() { selectedTaskId = viewTasks.last?.id }

    /// Returns true if a task was toggled.
    @discardableResult
    func toggleSelectedDone() -> Bool {
        guard let id = selectedTaskId else { return false }
        toggleDone(id)
        return true
    }

    /// Delete the selected task (and any descendants) and move selection to
    /// the nearest surviving neighbor.
    @discardableResult
    func deleteSelected() -> Bool {
        guard let id = selectedTaskId,
              let idx = viewTasks.firstIndex(where: { $0.id == id }) else { return false }
        deleteSubtree(id)
        let updated = viewTasks
        if updated.isEmpty {
            selectedTaskId = nil
        } else {
            selectedTaskId = updated[min(idx, updated.count - 1)].id
        }
        return true
    }

    /// Defer the selected task by the given interval (default 24h). Returns true if deferred.
    @discardableResult
    func deferSelected(by seconds: TimeInterval = 24 * 3600) -> Bool {
        guard let id = selectedTaskId else { return false }
        defer_(id, until: Date().addingTimeInterval(seconds))
        return true
    }

    /// Swap the selected task with the next task in the same sort group
    /// (matching done-state + due bucket). Returns true on success.
    @discardableResult
    func moveSelectedDown() -> Bool {
        guard let sid = selectedTaskId,
              let selected = tasks.first(where: { $0.id == sid }) else { return false }
        let visible = viewTasks
        guard let vidx = visible.firstIndex(where: { $0.id == sid }),
              vidx + 1 < visible.count else { return false }
        let neighbor = visible[vidx + 1]
        guard neighbor.isDone == selected.isDone, neighbor.due == selected.due else { return false }
        return swapInArray(sid, neighbor.id)
    }

    /// Swap the selected task with the previous task in the same sort group.
    @discardableResult
    func moveSelectedUp() -> Bool {
        guard let sid = selectedTaskId,
              let selected = tasks.first(where: { $0.id == sid }) else { return false }
        let visible = viewTasks
        guard let vidx = visible.firstIndex(where: { $0.id == sid }),
              vidx > 0 else { return false }
        let neighbor = visible[vidx - 1]
        guard neighbor.isDone == selected.isDone, neighbor.due == selected.due else { return false }
        return swapInArray(sid, neighbor.id)
    }

    private func swapInArray(_ a: String, _ b: String) -> Bool {
        guard let ai = tasks.firstIndex(where: { $0.id == a }),
              let bi = tasks.firstIndex(where: { $0.id == b }) else { return false }
        snapshot()
        // Swap `pos` values (sync-safe across devices) AND array positions
        // (cosmetic consistency with the raw `tasks` array).
        let aPos = tasks[ai].sortPos
        let bPos = tasks[bi].sortPos
        tasks[ai].pos = bPos
        tasks[bi].pos = aPos
        tasks.swapAt(ai, bi)
        return true
    }

    /// Drag-to-reorder within the current `viewTasks`. Assigns a fresh
    /// `pos` to the moved task that lands between its new neighbors, so
    /// the change syncs to other devices via Automerge (the raw task-list
    /// order isn't authoritative — pos is).
    ///
    /// `source` and `destination` follow SwiftUI's `List.onMove` semantic:
    /// destination is the insertion index in the CURRENT visible order
    /// (pre-removal), same shape as `Array.move(fromOffsets:toOffset:)`.
    func reorderView(from source: IndexSet, to destination: Int) {
        let view = viewTasks
        guard let src = source.first, src < view.count else { return }
        let movedId = view[src].id

        // Build the post-move visible ordering to find the moved task's
        // new neighbors.
        var reordered = view
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let newIdx = reordered.firstIndex(where: { $0.id == movedId }) else { return }
        if newIdx == src { return }   // no-op drop

        let prev: Date? = newIdx > 0 ? reordered[newIdx - 1].sortPos : nil
        let next: Date? = newIdx < reordered.count - 1 ? reordered[newIdx + 1].sortPos : nil

        // Midpoint between neighbors; fall back to a 1-minute offset when
        // we're at either end of the list.
        let newPos: Date
        switch (prev, next) {
        case let (p?, n?):
            newPos = Date(timeIntervalSince1970: (p.timeIntervalSince1970 + n.timeIntervalSince1970) / 2)
        case (let p?, nil):
            newPos = p.addingTimeInterval(60)
        case (nil, let n?):
            newPos = n.addingTimeInterval(-60)
        case (nil, nil):
            newPos = Date()
        }

        snapshot()
        guard let taskIdx = tasks.firstIndex(where: { $0.id == movedId }) else { return }
        tasks[taskIdx].pos = newPos
    }

    // MARK: - Cycle through lists

    /// Switch to the next list in the sidebar order (wraps at the end).
    /// Clears any active context filter and selects the first task of the new list.
    func selectNextList() { cycleList(by: +1) }

    /// Switch to the previous list (wraps at the beginning).
    func selectPreviousList() { cycleList(by: -1) }

    /// Jump to a list by its index in `allLists` (0 = inbox). No-op if out of range.
    @discardableResult
    func gotoList(at index: Int) -> Bool {
        let lists = allLists
        guard index >= 0, index < lists.count else { return false }
        activeContextFilter = nil
        activeSelection = .list(lists[index].id)
        selectFirst()
        return true
    }

    /// Move the selected task to a list by its index in `allLists`. No-op if
    /// out of range or no task is selected.
    @discardableResult
    func moveSelectedToList(at index: Int) -> Bool {
        guard let sid = selectedTaskId else { return false }
        let lists = allLists
        guard index >= 0, index < lists.count else { return false }
        move(sid, toList: lists[index].id)
        return true
    }

    /// Clear the active context filter. Returns true if something changed.
    @discardableResult
    func clearContextFilter() -> Bool {
        guard activeContextFilter != nil else { return false }
        activeContextFilter = nil
        return true
    }

    private func cycleList(by delta: Int) {
        let lists = allLists
        guard !lists.isEmpty else { return }
        let currentIndex: Int
        if activeContextFilter != nil {
            // A context filter is on — first press cancels the filter and stays
            // on the current list. This mirrors typical "back out of filter" UX.
            activeContextFilter = nil
            return
        }
        if case .list(let id) = activeSelection,
           let i = lists.firstIndex(where: { $0.id == id }) {
            currentIndex = i
        } else {
            currentIndex = 0
        }
        let next = ((currentIndex + delta) % lists.count + lists.count) % lists.count
        activeSelection = .list(lists[next].id)
        activeContextFilter = nil
        selectFirst()
    }
}
