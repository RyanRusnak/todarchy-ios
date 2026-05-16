import Foundation
import SwiftUI

// GTD-light data model. Schema matches the Linux companion app exactly so a
// shared Automerge doc round-trips across devices.

/// A user-editable context label (`@work`, `@home`, `@banana`, ...).
/// Kept as a thin wrapper so existing call-sites using `.work` / `.allCases`
/// continue to compile after the switch from a fixed enum to free-form strings.
struct TaskContext: Hashable, Codable, Identifiable {
    let rawValue: String

    var id: String { rawValue }
    var label: String { rawValue }

    init(rawValue: String) {
        // Normalize: always has a single leading @, lowercased.
        var v = rawValue.lowercased().trimmingCharacters(in: .whitespaces)
        if !v.hasPrefix("@") { v = "@" + v }
        self.rawValue = v
    }

    /// Accept anything Codable writes as a plain string (no wrapping object).
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(rawValue: try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    // MARK: - Built-ins

    static let home    = TaskContext(rawValue: "@home")
    static let work    = TaskContext(rawValue: "@work")
    static let errands = TaskContext(rawValue: "@errands")
    static let phone   = TaskContext(rawValue: "@phone")
    static let mac     = TaskContext(rawValue: "@mac")
    static let read    = TaskContext(rawValue: "@read")

    /// The seed set used when a new doc is created. Users can add/remove via
    /// the context editor; the Automerge doc stores the authoritative list.
    static let allCases: [TaskContext] = [.home, .work, .errands, .phone, .mac, .read]

    /// Theme color. Built-in names keep their hand-tuned palette slot; any
    /// user-defined context gets a deterministic pick from `paletteFallback`
    /// so it has stable identity across launches without us needing to
    /// persist a per-context color.
    var color: Color {
        switch rawValue {
        case "@home": return Theme.cyan
        case "@work": return Theme.accent
        case "@errands": return Theme.warn
        case "@mac": return Theme.accent2
        case "@phone": return Theme.success
        case "@read": return Theme.orange
        default: return Self.paletteFallback(for: rawValue)
        }
    }

    /// Hashes the raw string into one of the theme's accent-ish colors.
    /// Stable across launches because we use a custom FNV-1a (Swift's
    /// built-in `hashValue` is randomized per-process).
    private static func paletteFallback(for raw: String) -> Color {
        let palette: [Color] = [
            Theme.accent, Theme.accent2, Theme.cyan, Theme.success,
            Theme.warn, Theme.orange, Theme.blue, Theme.purple,
        ]
        var h: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return palette[Int(h % UInt64(palette.count))]
    }
}

enum DueBucket: String, CaseIterable, Identifiable, Codable {
    case today
    case tomorrow
    case thisWeek = "this week"

    var id: String { rawValue }
    var label: String { rawValue }
    var token: String {
        switch self {
        case .today: return "!today"
        case .tomorrow: return "!tomorrow"
        case .thisWeek: return "!week"
        }
    }

    var color: Color {
        switch self {
        case .today: return Theme.danger
        case .tomorrow: return Theme.warn
        case .thisWeek: return Theme.blue
        }
    }

    var sortOrder: Int {
        switch self {
        case .today: return 0
        case .tomorrow: return 1
        case .thisWeek: return 2
        }
    }
}

/// A task. Fields match the Linux doc exactly (see README §Sync architecture).
///
/// `id` and `parent` are `String` — NOT `UUID` — because the Automerge doc
/// is shared across Swift/Rust/JS clients and the Linux app ships non-UUID
/// ids (short base36). Swift's `UUID(uuidString:)` returns nil for those,
/// so any attempt to strict-parse silently drops tasks from the UI. Keep
/// as `String`, validate elsewhere if you must.
/// Append-only conversation entry on a task. Used for human↔human and
/// human↔Claude back-and-forth. Edits / deletes are intentionally not
/// supported in v1 — append-only keeps merge semantics simple and
/// removes "who deleted that?" ambiguity between devices.
struct Comment: Identifiable, Hashable, Codable {
    var id: String = Self.newID()
    /// Display name of whoever posted. Currently from a per-device
    /// preference (UserDefaults), defaulting to "Me". MCP server
    /// invocations will pass a configurable name (e.g. "Claude").
    var author: String
    var text: String
    var createdAt: Date = Date()

    static func newID() -> String { UUID().uuidString.lowercased() }

    private enum CodingKeys: String, CodingKey {
        case id, author, text, createdAt
    }

    init(id: String = Comment.newID(),
         author: String,
         text: String,
         createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.author = try c.decode(String.self, forKey: .author)
        self.text = try c.decode(String.self, forKey: .text)
        self.createdAt = Date(millisecondsSince1970: try c.decode(Int64.self, forKey: .createdAt))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt.millisecondsSince1970, forKey: .createdAt)
    }
}

struct TaskItem: Identifiable, Hashable, Codable {
    var id: String = Self.newID()
    var list: String                // "inbox" or "p_<id>"
    var title: String
    var ctx: TaskContext?
    var due: DueBucket?
    var note: String = ""
    var created: Date = Date()
    var doneAt: Date?
    var deferUntil: Date?
    var parent: String?
    /// Manual sort key in ms-epoch. Defaults to `created`. Reordering mutates
    /// this so device A's reorder reaches device B through Automerge.
    var pos: Date?
    /// Conversation entries on the task — see `Comment`. Append-only.
    /// Stored in Automerge as a Map<commentId, Comment> so concurrent
    /// inserts on two devices both survive merge (same load-bearing
    /// rationale as tasks/projects keyed by id).
    var comments: [Comment] = []

    var isDone: Bool { doneAt != nil }
    var isDeferred: Bool {
        guard let d = deferUntil else { return false }
        return d > Date()
    }

    var sortPos: Date { pos ?? created }

    /// Swift-side ids stay UUID-shaped (lowercased). Other platforms can
    /// ship anything string-shaped; we accept them without parsing.
    static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: - Codable: linux-compat shape

    private enum CodingKeys: String, CodingKey {
        case id, list, title, ctx, due, note
        case created, doneAt, deferUntil, parent, pos, comments
    }

    init(
        id: String = TaskItem.newID(),
        list: String,
        title: String,
        ctx: TaskContext? = nil,
        note: String = "",
        created: Date = Date(),
        due: DueBucket? = nil,
        deferUntil: Date? = nil,
        doneAt: Date? = nil,
        parent: String? = nil,
        pos: Date? = nil,
        comments: [Comment] = []
    ) {
        self.id = id
        self.list = list
        self.title = title
        self.ctx = ctx
        self.due = due
        self.note = note
        self.created = created
        self.doneAt = doneAt
        self.deferUntil = deferUntil
        self.parent = parent
        self.comments = comments
        self.pos = pos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.list = try c.decode(String.self, forKey: .list)
        self.title = try c.decode(String.self, forKey: .title)
        self.ctx = try c.decodeIfPresent(TaskContext.self, forKey: .ctx)
        // Linux writes "" for "no due"; normalize.
        let dueStr = try c.decodeIfPresent(String.self, forKey: .due)
        self.due = (dueStr?.isEmpty == false) ? DueBucket(rawValue: dueStr!) : nil
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.created = Date(millisecondsSince1970: try c.decode(Int64.self, forKey: .created))
        if let ms = try c.decodeIfPresent(Int64.self, forKey: .doneAt) {
            self.doneAt = Date(millisecondsSince1970: ms)
        }
        if let ms = try c.decodeIfPresent(Int64.self, forKey: .deferUntil) {
            self.deferUntil = Date(millisecondsSince1970: ms)
        }
        self.parent = try c.decodeIfPresent(String.self, forKey: .parent)
        if let ms = try c.decodeIfPresent(Int64.self, forKey: .pos) {
            self.pos = Date(millisecondsSince1970: ms)
        }
        // Older docs / non-Swift peers won't include `comments`;
        // default to an empty list so existing snapshots decode.
        self.comments = (try? c.decode([Comment].self, forKey: .comments)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(list, forKey: .list)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(ctx, forKey: .ctx)
        try c.encode(due?.rawValue ?? "", forKey: .due)
        try c.encode(note, forKey: .note)
        try c.encode(created.millisecondsSince1970, forKey: .created)
        try c.encodeIfPresent(doneAt?.millisecondsSince1970, forKey: .doneAt)
        try c.encodeIfPresent(deferUntil?.millisecondsSince1970, forKey: .deferUntil)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(pos?.millisecondsSince1970, forKey: .pos)
        if !comments.isEmpty {
            try c.encode(comments, forKey: .comments)
        }
    }
}

struct ProjectItem: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var icon: String
    var accentHex: UInt32
    var isInbox: Bool = false
    /// True when this project's tasks live in a separate encrypted file
    /// (`shared_<id>.automerge.enc`) managed by `PerProjectStore`. The
    /// main doc keeps only the project's metadata + this flag. Absent /
    /// false in older docs and on clients that don't implement sharing
    /// yet, so it's safe to introduce without a migration.
    var isShared: Bool = false
    /// True when the user has granted the MCP server (Claude) read/write
    /// access to this project's tasks. Synced via main-doc so the
    /// "Claude can see X" toggle is visible on every device, even
    /// though the MCP server itself only runs on the Mac (today).
    /// Defaults to false — Claude access is opt-in.
    var claudeAccess: Bool = false

    var accent: Color { Color(hex: accentHex) }

    init(id: String,
         name: String,
         icon: String,
         accent: Color,
         isInbox: Bool = false,
         isShared: Bool = false,
         claudeAccess: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accent.argbHex
        self.isInbox = isInbox
        self.isShared = isShared
        self.claudeAccess = claudeAccess
    }

    init(id: String,
         name: String,
         icon: String,
         accentHex: UInt32,
         isInbox: Bool = false,
         isShared: Bool = false,
         claudeAccess: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.isInbox = isInbox
        self.isShared = isShared
        self.claudeAccess = claudeAccess
    }

    // MARK: - Codable: linux-compat shape

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, accent, isInbox, isShared, claudeAccess
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        // Linux stores accent as a CSS hex string (e.g. "#7aa2f7"). Accept both
        // numeric hex and string forms.
        if let hex = try? c.decode(UInt32.self, forKey: .accent) {
            self.accentHex = hex
        } else if let str = try? c.decode(String.self, forKey: .accent) {
            let trimmed = str.hasPrefix("#") ? String(str.dropFirst()) : str
            self.accentHex = UInt32(trimmed, radix: 16) ?? 0x7AA2F7
        } else {
            self.accentHex = 0x7AA2F7
        }
        self.isInbox = try c.decodeIfPresent(Bool.self, forKey: .isInbox) ?? false
        self.isShared = try c.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
        self.claudeAccess = try c.decodeIfPresent(Bool.self, forKey: .claudeAccess) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        // Write as CSS hex so the linux app can read it.
        let hexStr = String(format: "#%06x", accentHex)
        try c.encode(hexStr, forKey: .accent)
        if isInbox { try c.encode(true, forKey: .isInbox) }
        // Only emit isShared when true so we don't churn older docs that
        // never had the field. Linux and other clients that predate this
        // field just ignore it; they'll see the project record but
        // (correctly) won't know it's externally stored until they
        // implement the shared-file path themselves.
        if isShared { try c.encode(true, forKey: .isShared) }
        // Same emit-when-true rule for claudeAccess — keeps existing
        // bytes stable for projects that have never had the flag set.
        if claudeAccess { try c.encode(true, forKey: .claudeAccess) }
    }
}

enum Selection: Hashable {
    case list(String)
    case context(TaskContext)
}

// Stable identifier for this device (used in logs; the Automerge actor id is
// the authoritative identity for sync merges).
enum DeviceID {
    private static let key = "todarchy.deviceId"
    static var current: String = {
        if let saved = UserDefaults.standard.string(forKey: key) {
            return saved
        }
        let fresh = "\(platformTag)-\(UUID().uuidString.prefix(8).lowercased())"
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    /// "macos-Ryans-MacBook-Pro", "ios-Ryans-iPhone", "linux-desktop" etc.
    /// Derived from the device's own host name when available.
    static var humanReadable: String {
        #if os(macOS)
        let host = Host.current().localizedName ?? "Mac"
        return host
        #else
        #if canImport(UIKit)
        return UIDevice.current.name  // "Ryan's iPhone"
        #else
        return "Device"
        #endif
        #endif
    }

    private static var platformTag: String {
        #if os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }

}

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Date <-> ms epoch

extension Date {
    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }

    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
