import Foundation
import Automerge
import os.log

/// Wraps an Automerge `Document` as the canonical, sync-ready store for tasks.
///
/// The doc's shape is fixed by the cross-platform schema contract (shared
/// with the Linux app):
///
///     {
///       version  : Int64 = 1,
///       contexts : List<String>,                 // user-editable labels
///       tasks    : Map<id, Task>,                // keyed by task.id (String)
///       projects : Map<id, Project>,             // keyed by project.id
///     }
///
/// Keying tasks/projects by id (NOT a list) is load-bearing: concurrent
/// inserts on two devices land at two different keys, so both survive merge.
/// A list would have both inserts target the same index and Automerge would
/// drop one.
///
/// Saves are UPSERT-ONLY. Never delete map keys to reflect "task missing
/// from my local snapshot" — that would tombstone another device's
/// just-added task. Callers must call `deleteTask(id:)` / `deleteProject(id:)`
/// explicitly when the user actually deletes.
final class AutomergeStore {
    private static let log = Logger(subsystem: "todarchy", category: "sync")
    private var doc: Document
    /// Serializes all accesses to `doc`. Automerge's internal per-op lock
    /// isn't enough — our upsertTask does multiple ops, and merges span many
    /// ops; if the file-watcher thread sneaks in between we get interleaved
    /// states that can surface as PatchLogMismatch panics.
    private let docLock = NSRecursiveLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        docLock.lock()
        defer { docLock.unlock() }
        return try body()
    }

    /// Canonical actor id used for the initial shape ops (version, root
    /// tasks/projects/contexts objects, seed context values). Every device
    /// starts from the same seed bytes, so these ops dedupe on merge — the
    /// root "tasks" key points at the same map object everywhere.
    private static let seedActor: ActorId = {
        let uuid = UUID(uuidString: "544F4441-5243-4859-5345-454400000001") ?? UUID()
        return ActorId(uuid: uuid)
    }()

    /// Byte-identical seed produced once per process. Applying `setActor`
    /// only happens on a brand-new `Document()` *before* any ops run —
    /// `setActor` after ops throws a PatchLogMismatch panic, so don't do it.
    private static let seedBytes: Data = {
        let doc = Document()
        doc.actor = seedActor
        try? ensureShape(in: doc)
        return doc.save()
    }()

    init() {
        // Load the canonical seed; fork to get a unique actor for this
        // device's ops. `fork()` is the supported way to change actors
        // post-load.
        let seeded = (try? Document(Self.seedBytes)) ?? Document()
        self.doc = seeded.fork()
    }

    /// Load from raw .automerge bytes. Falls back to the canonical seed when
    /// the bytes are missing or unparseable. Always `fork()` so this device
    /// writes under a distinct actor id.
    init(data: Data?) {
        if let data, let loaded = try? Document(data) {
            self.doc = loaded.fork()
            try? Self.ensureShape(in: self.doc)
        } else {
            let seeded = (try? Document(Self.seedBytes)) ?? Document()
            self.doc = seeded.fork()
        }
    }

    /// Serialize to bytes for disk.
    func save() -> Data {
        locked { doc.save() }
    }

    /// Merge another doc into this one. Used when the underlying file has
    /// been changed externally (iCloud / Dropbox / Syncthing).
    func merge(_ other: AutomergeStore) throws {
        // Grab a snapshot of `other` under its own lock, then merge under
        // ours. Merging directly under both would need a consistent lock
        // order.
        let otherBytes = other.save()
        guard let otherCopy = try? Document(otherBytes) else { return }
        try locked { try doc.merge(other: otherCopy) }
    }

    // MARK: - Shape bootstrap

    /// Guarantee the root maps/lists exist with the seed contexts. Safe to
    /// call repeatedly.
    private static func ensureShape(in doc: Document) throws {
        if try doc.get(obj: ObjId.ROOT, key: "version") == nil {
            try doc.put(obj: ObjId.ROOT, key: "version", value: .Int(1))
        }
        if try doc.get(obj: ObjId.ROOT, key: "tasks") == nil {
            _ = try doc.putObject(obj: ObjId.ROOT, key: "tasks", ty: .Map)
        }
        if try doc.get(obj: ObjId.ROOT, key: "projects") == nil {
            _ = try doc.putObject(obj: ObjId.ROOT, key: "projects", ty: .Map)
        }
        if try doc.get(obj: ObjId.ROOT, key: "contexts") == nil {
            let list = try doc.putObject(obj: ObjId.ROOT, key: "contexts", ty: .List)
            for (i, c) in TaskContext.allCases.enumerated() {
                try doc.insert(obj: list, index: UInt64(i), value: .String(c.rawValue))
            }
        }
    }

    // MARK: - Snapshot conversion

    /// Rebuild an in-memory snapshot from the doc. Tasks are sorted by pos
    /// ASC (with `created` as fallback) so the TaskStore's raw array matches
    /// the displayed top-to-bottom, oldest-first order.
    func snapshot() throws -> TaskStorePersistence.Snapshot {
        try locked {
            let tasks = try readTasks().sorted { $0.sortPos < $1.sortPos }
            let projects = try readProjects()
            let contexts = try readContexts()
            return TaskStorePersistence.Snapshot(
                tasks: tasks, projects: projects, contexts: contexts
            )
        }
    }

    /// Replace the persisted contexts list with `contexts`. Used by the
    /// editor sheet (add/remove/rename). Idempotent; safe to call from
    /// scheduleSave on every tick — we only rewrite when the list differs
    /// to avoid pointless Automerge churn.
    func writeContexts(_ contexts: [TaskContext]) throws {
        try locked {
            let current = try readContexts() ?? []
            if current == contexts { return }
            let listObj = try requireList(key: "contexts")
            let len = try doc.length(obj: listObj)
            // Clear then reinsert. This isn't great for merge semantics
            // (two devices editing concurrently can produce duplicates)
            // but the contexts list is short and edits are rare. If it
            // becomes a problem we can move to per-context map keys.
            for _ in 0..<len {
                try doc.delete(obj: listObj, index: 0)
            }
            for (i, c) in contexts.enumerated() {
                try doc.insert(obj: listObj, index: UInt64(i), value: .String(c.rawValue))
            }
        }
    }

    private func readContexts() throws -> [TaskContext]? {
        guard case let .Object(listId, .List) = try doc.get(obj: ObjId.ROOT, key: "contexts") else {
            return nil
        }
        let len = try doc.length(obj: listId)
        var out: [TaskContext] = []
        out.reserveCapacity(Int(len))
        for i in 0..<len {
            if case let .Scalar(.String(s)) = try doc.get(obj: listId, index: i) {
                out.append(TaskContext(rawValue: s))
            }
        }
        return out
    }

    private func requireList(key: String) throws -> ObjId {
        if case let .Object(objId, .List) = try doc.get(obj: ObjId.ROOT, key: key) {
            return objId
        }
        return try doc.putObject(obj: ObjId.ROOT, key: key, ty: .List)
    }

    // MARK: - Upsert / delete (mutation API)

    /// Upsert a task at its own id. Never touches other keys.
    func upsertTask(_ task: TaskItem) throws {
        try locked { try upsertTaskUnlocked(task) }
    }

    private func upsertTaskUnlocked(_ task: TaskItem) throws {
        let tasksMap = try requireMap(key: "tasks")
        let key = task.id
        let obj: ObjId
        if let existing = try doc.get(obj: tasksMap, key: key),
           case let .Object(existingId, .Map) = existing {
            obj = existingId
        } else {
            obj = try doc.putObject(obj: tasksMap, key: key, ty: .Map)
        }
        try writeTask(task, into: obj)
    }

    /// Upsert a batch. Absent keys are left alone — this is the path
    /// TaskStorePersistence uses on every scheduled save.
    func upsertTasks(_ tasks: [TaskItem]) throws {
        try locked {
            for task in tasks {
                try upsertTaskUnlocked(task)
            }
        }
    }

    /// Explicit delete. Produces a real Automerge tombstone so the deletion
    /// propagates on merge.
    func deleteTask(_ id: String) throws {
        locked {
            let tasksMap = (try? requireMap(key: "tasks"))
            if let tasksMap {
                try? doc.delete(obj: tasksMap, key: id)
            }
        }
    }

    func upsertProject(_ project: ProjectItem) throws {
        try locked { try upsertProjectUnlocked(project) }
    }

    private func upsertProjectUnlocked(_ project: ProjectItem) throws {
        let projectsMap = try requireMap(key: "projects")
        let obj: ObjId
        if let existing = try doc.get(obj: projectsMap, key: project.id),
           case let .Object(existingId, .Map) = existing {
            obj = existingId
        } else {
            obj = try doc.putObject(obj: projectsMap, key: project.id, ty: .Map)
        }
        try writeProject(project, into: obj)
    }

    func upsertProjects(_ projects: [ProjectItem]) throws {
        try locked {
            for p in projects { try upsertProjectUnlocked(p) }
        }
    }

    func deleteProject(_ id: String) throws {
        locked {
            if let projectsMap = try? requireMap(key: "projects") {
                try? doc.delete(obj: projectsMap, key: id)
            }
        }
    }

    // MARK: - Internal helpers

    private func requireMap(key: String) throws -> ObjId {
        if case let .Object(objId, .Map) = try doc.get(obj: ObjId.ROOT, key: key) {
            return objId
        }
        // Missing or wrong type — (re)create as a Map.
        return try doc.putObject(obj: ObjId.ROOT, key: key, ty: .Map)
    }

    // MARK: - Tasks

    private func readTasks() throws -> [TaskItem] {
        let map = try requireMap(key: "tasks")
        let entries = try doc.mapEntries(obj: map)
        var out: [TaskItem] = []
        out.reserveCapacity(entries.count)
        for (_, value) in entries {
            if case let .Object(taskObj, .Map) = value {
                if let t = try readTask(taskObj) { out.append(t) }
            }
        }
        return out
    }

    private func readTask(_ obj: ObjId) throws -> TaskItem? {
        let rawId = try stringValue(obj: obj, key: "id")
        guard let id = rawId else {
            Self.log.error("readTask: missing 'id' field")
            return nil
        }
        guard let list = try stringValue(obj: obj, key: "list") else {
            Self.log.error("readTask: task id=\(id, privacy: .public) missing 'list' field")
            return nil
        }
        guard let title = try stringValue(obj: obj, key: "title") else {
            Self.log.error("readTask: task id=\(id, privacy: .public) missing 'title' field")
            return nil
        }
        let createdMs = try intValue(obj: obj, key: "created") ?? 0
        var task = TaskItem(
            id: id, list: list, title: title,
            note: try stringValue(obj: obj, key: "note") ?? "",
            created: Date(millisecondsSince1970: createdMs)
        )
        if let ctxStr = try stringValue(obj: obj, key: "ctx"), !ctxStr.isEmpty {
            task.ctx = TaskContext(rawValue: ctxStr)
        }
        if let dueStr = try stringValue(obj: obj, key: "due"), !dueStr.isEmpty {
            task.due = DueBucket(rawValue: dueStr)
        }
        if let ms = try intValue(obj: obj, key: "doneAt") { task.doneAt = Date(millisecondsSince1970: ms) }
        if let ms = try intValue(obj: obj, key: "deferUntil") { task.deferUntil = Date(millisecondsSince1970: ms) }
        if let p = try stringValue(obj: obj, key: "parent") {
            task.parent = p
        }
        if let ms = try intValue(obj: obj, key: "pos") { task.pos = Date(millisecondsSince1970: ms) }
        return task
    }

    private func writeTask(_ task: TaskItem, into obj: ObjId) throws {
        try doc.put(obj: obj, key: "id", value: .String(task.id))
        try doc.put(obj: obj, key: "list", value: .String(task.list))
        try doc.put(obj: obj, key: "title", value: .String(task.title))
        try doc.put(obj: obj, key: "ctx", value: .String(task.ctx?.rawValue ?? ""))
        try doc.put(obj: obj, key: "due", value: .String(task.due?.rawValue ?? ""))
        try doc.put(obj: obj, key: "note", value: .String(task.note))
        try doc.put(obj: obj, key: "created", value: .Int(task.created.millisecondsSince1970))
        if let d = task.doneAt {
            try doc.put(obj: obj, key: "doneAt", value: .Int(d.millisecondsSince1970))
        } else {
            try? doc.delete(obj: obj, key: "doneAt")
        }
        if let d = task.deferUntil {
            try doc.put(obj: obj, key: "deferUntil", value: .Int(d.millisecondsSince1970))
        } else {
            try? doc.delete(obj: obj, key: "deferUntil")
        }
        if let p = task.parent {
            try doc.put(obj: obj, key: "parent", value: .String(p))
        } else {
            try? doc.delete(obj: obj, key: "parent")
        }
        if let d = task.pos {
            try doc.put(obj: obj, key: "pos", value: .Int(d.millisecondsSince1970))
        } else {
            try? doc.delete(obj: obj, key: "pos")
        }
    }

    // MARK: - Projects

    private func readProjects() throws -> [ProjectItem] {
        let map = try requireMap(key: "projects")
        let entries = try doc.mapEntries(obj: map)
        var out: [ProjectItem] = []
        for (mapKey, value) in entries {
            guard case let .Object(obj, .Map) = value else { continue }
            let rawId = try stringValue(obj: obj, key: "id")
            guard let id = rawId else {
                Self.log.error("readProject: mapKey=\(mapKey, privacy: .public) missing 'id' field")
                continue
            }
            guard let name = try stringValue(obj: obj, key: "name") else {
                Self.log.error("readProject: project id=\(id, privacy: .public) missing 'name' field")
                continue
            }
            let icon = try stringValue(obj: obj, key: "icon") ?? "folder"
            let accent: UInt32
            if let s = try stringValue(obj: obj, key: "accent") {
                let trimmed = s.hasPrefix("#") ? String(s.dropFirst()) : s
                accent = UInt32(trimmed, radix: 16) ?? 0x7AA2F7
            } else {
                accent = 0x7AA2F7
            }
            let isShared = (try boolValue(obj: obj, key: "isShared")) ?? false
            out.append(ProjectItem(id: id, name: name, icon: icon,
                                    accentHex: accent, isShared: isShared))
        }
        // Deterministic order for the UI — alphabetic by name, inbox-first
        // semantics are handled by TaskStore.allLists.
        return out.sorted { $0.name < $1.name }
    }

    private func writeProject(_ p: ProjectItem, into obj: ObjId) throws {
        try doc.put(obj: obj, key: "id", value: .String(p.id))
        try doc.put(obj: obj, key: "name", value: .String(p.name))
        try doc.put(obj: obj, key: "icon", value: .String(p.icon))
        try doc.put(obj: obj, key: "accent", value: .String(String(format: "#%06x", p.accentHex)))
        if p.isShared {
            try doc.put(obj: obj, key: "isShared", value: .Boolean(true))
        } else {
            // Drop the key when false so docs that never had the field
            // stay byte-stable.
            try? doc.delete(obj: obj, key: "isShared")
        }
    }

    // MARK: - Share keys
    //
    // Top-level `shareKeys` map carries the per-user passphrase
    // material:
    //
    //     shareKeys: {
    //       version: Int64 = 1,        // wire-format version
    //       salt:    Bytes(16),        // Argon2 salt
    //       cipher:  Bytes(opt),       // sealed {projectId → keyBytes}
    //     }
    //
    // The map is created lazily on first write — fresh docs without
    // any shared lists carry no `shareKeys` field at all, which keeps
    // their serialized bytes byte-stable for users who never share.
    // Reads return nil for uninitialised fields rather than throwing.

    /// Wire-format version of the share-keys blob, or nil if shareKeys
    /// hasn't been initialised on this device.
    func readShareKeysVersion() throws -> Int64? {
        try locked {
            guard let mapId = try shareKeysMapId() else { return nil }
            return try intValue(obj: mapId, key: "version")
        }
    }

    /// 16-byte salt used to derive the master key from the user's
    /// passphrase. Nil if shareKeys hasn't been initialised yet.
    func readShareKeysSalt() throws -> Data? {
        try locked {
            guard let mapId = try shareKeysMapId() else { return nil }
            return try bytesValue(obj: mapId, key: "salt")
        }
    }

    /// The sealed `{projectId → keyBytes}` blob (a `CryptoBox` envelope
    /// produced by `ShareKeysMap.seal(with:)`). Nil if no shares have
    /// been recorded yet, even when salt is set.
    func readShareKeysCipher() throws -> Data? {
        try locked {
            guard let mapId = try shareKeysMapId() else { return nil }
            return try bytesValue(obj: mapId, key: "cipher")
        }
    }

    /// Write the salt. Stamps `version = 1` the first time. Idempotent
    /// when the same salt is already present — important because the
    /// caller may invoke this on every passphrase setup attempt.
    func writeShareKeysSalt(_ salt: Data) throws {
        try locked {
            let mapId = try requireShareKeysMap()
            // Always write version so older docs that pre-date the
            // field pick it up too.
            if try intValue(obj: mapId, key: "version") != 1 {
                try doc.put(obj: mapId, key: "version", value: .Int(1))
            }
            if try bytesValue(obj: mapId, key: "salt") != salt {
                try doc.put(obj: mapId, key: "salt", value: .Bytes(salt))
            }
        }
    }

    /// Write the sealed envelope. The caller is responsible for
    /// producing this via `ShareKeysMap.seal(with:)` under the
    /// current master key.
    func writeShareKeysCipher(_ cipher: Data) throws {
        try locked {
            let mapId = try requireShareKeysMap()
            try doc.put(obj: mapId, key: "cipher", value: .Bytes(cipher))
        }
    }

    /// Wipe the entire `shareKeys` map. Used for the "Reset shared
    /// lists" flow where the user forgot their passphrase — they
    /// re-set one from scratch and re-accept share links.
    func clearShareKeys() throws {
        try locked {
            // Only delete if it actually exists; otherwise we'd get
            // a missing-key error from Automerge.
            if try shareKeysMapId() != nil {
                try? doc.delete(obj: ObjId.ROOT, key: "shareKeys")
            }
        }
    }

    private func shareKeysMapId() throws -> ObjId? {
        guard case let .Object(objId, .Map) = try doc.get(obj: ObjId.ROOT, key: "shareKeys") else {
            return nil
        }
        return objId
    }

    private func requireShareKeysMap() throws -> ObjId {
        if let existing = try shareKeysMapId() { return existing }
        return try doc.putObject(obj: ObjId.ROOT, key: "shareKeys", ty: .Map)
    }

    private func bytesValue(obj: ObjId, key: String) throws -> Data? {
        if case let .Scalar(.Bytes(d)) = try doc.get(obj: obj, key: key) { return d }
        return nil
    }

    // MARK: - Primitive readers

    private func stringValue(obj: ObjId, key: String) throws -> String? {
        if case let .Scalar(.String(s)) = try doc.get(obj: obj, key: key) { return s }
        return nil
    }

    private func intValue(obj: ObjId, key: String) throws -> Int64? {
        switch try doc.get(obj: obj, key: key) {
        case let .Scalar(.Int(v)): return v
        case let .Scalar(.Uint(v)): return Int64(v)
        default: return nil
        }
    }

    private func boolValue(obj: ObjId, key: String) throws -> Bool? {
        if case let .Scalar(.Boolean(v)) = try doc.get(obj: obj, key: key) { return v }
        return nil
    }
}
