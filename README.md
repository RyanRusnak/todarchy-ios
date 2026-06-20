# todarchy

A keyboard-first, GTD-light todo app for **Mac, iPhone, and iPad**, built with
SwiftUI. It stores everything in a single [Automerge](https://automerge.org)
CRDT document, so it syncs cleanly across devices — and with the
[Linux companion app](https://github.com/RyanRusnak/todarchy-linux) — over
whatever transport you choose: a file-sync folder you already use (Dropbox,
iCloud Drive, Syncthing), a self-hostable relay server, or nothing at all
(local-only).

It also speaks **MCP**, so Claude (or any MCP client) can read and update the
projects you explicitly grant it access to.

- **No account required.** No sign-up, no vendor lock-in. Your data is a file.
- **Offline-first.** Everything works without a network; it reconciles when a
  peer shows up.
- **Opinionated about ergonomics, neutral about storage.** Type `a`, capture a
  task, move on — but put the data wherever you like.

---

## Table of contents

- [Concepts](#concepts)
- [Installing & building](#installing--building)
- [Basic usage](#basic-usage)
  - [Capturing tasks & quick-add syntax](#capturing-tasks--quick-add-syntax)
  - [Completing, editing, organizing](#completing-editing-organizing)
  - [List modes & filters](#list-modes--filters)
  - [Subtasks (nesting)](#subtasks-nesting)
  - [Comments](#comments)
  - [Voice capture](#voice-capture)
  - [Themes](#themes)
- [Keyboard control (Mac)](#keyboard-control-mac)
- [Syncing across devices](#syncing-across-devices)
  - [Local-only](#local-only)
  - [Folder sync](#folder-sync)
  - [Server sync (self-hostable relay)](#server-sync-self-hostable-relay)
- [Sharing lists with other people](#sharing-lists-with-other-people)
- [AI access (Claude / MCP)](#ai-access-claude--mcp)
- [Architecture](#architecture)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

---

## Concepts

| Term | What it is |
|------|------------|
| **Task** | A single to-do. Has a title, an optional context, due bucket, defer date, a markdown **body/note**, and a comment thread. |
| **Inbox** | The default catch-all list. Every device has one; it can't be deleted or shared. |
| **Project / List** | A named, colored, icon'd list you create (e.g. *work*, *home*, *wedding planning*). "Project" and "list" are the same thing. |
| **Context** | A free-form `@label` describing *where/how* a task gets done — `@work`, `@home`, `@phone`, `@mac`, `@errands`, `@read` ship as defaults, and any new `@token` you type is auto-registered. Cuts across projects. |
| **Due bucket** | A coarse deadline: `!today`, `!tomorrow`, `!week`. Intentionally fuzzy — todarchy is GTD-light, not a calendar. |
| **Defer** | Hide a task until a date. Deferred tasks drop out of the default view until they're due. |
| **Subtask** | Any task can be nested under a parent (indent/outdent). Collapsing a parent hides its children. |
| **Comment** | An append-only note on a task. The channel for human↔human and human↔Claude back-and-forth. |

Under the hood it's all one document with a fixed shape (`version`, `contexts`,
`tasks` keyed by id, `projects` keyed by id) — see [Architecture](#architecture).

---

## Installing & building

### Requirements

- macOS 14+ and/or iOS 17+
- Xcode 16+
- Ruby (only if you change the file layout — it regenerates the Xcode project)

### Build

```bash
git clone <this repo>
cd todarchy
ruby generate_project.rb     # regenerates todarchy.xcodeproj from the file tree
open todarchy.xcodeproj
```

In Xcode, pick your development team for the targets (the repo ships with an
empty team ID so you don't inherit someone else's signing identity), then build
and run — the **macOS** destination for Mac, any iOS simulator or device for
iPhone/iPad.

There are three schemes that matter:

- `todarchy` — the app (all platforms).
- `todarchy-mcp` — the command-line MCP server (see [AI access](#ai-access-claude--mcp)).
- `Automerge` / `MarkdownUI` / `Argon2` — vendored dependencies; you won't build these directly.

---

## Basic usage

### Capturing tasks & quick-add syntax

Press `a` (or `o`, `Return`, `⌘N`) on Mac, or tap the **+** on iOS, to open the
capture field. Type a line and the **quick-add parser** pulls structured chips
out of it automatically:

| You type | Parsed as |
|----------|-----------|
| `@work`, `@home`, `@anything` | **context** (anything after `@` becomes a context; new ones auto-register) |
| `!today` / `!tomorrow` / `!week` | **due bucket** |
| ` /the rest of the line` | everything after a space-slash becomes the **note/body** |
| the leftover words | the **title** |

Example:

```
call mom @phone !today /ask about the flights to lisbon
```

→ title **"call mom"**, context **@phone**, due **today**, note **"ask about the
flights to lisbon"**.

New tasks land at the bottom of their list (work top-down, check off, move on).
On Mac, the capture sheet has a *stay-open* mode so you can fire off several in a
row, and a **system-wide global hotkey (⌥Space)** summons it from any app. The
**menu-bar quick-add** is separate: whatever you type there always lands in the
inbox, regardless of which project the main window is showing.

### Completing, editing, organizing

- **Complete / un-complete:** click the checkbox, press `x`/`Space` on the
  selected row, or swipe (iOS).
- **Edit title:** press `e` (Mac) or double-click a row.
- **Edit body, context, due, defer:** open the **inspector** (`i` on Mac, or tap
  into a task on iOS). The body is full markdown.
- **Move to another list:** `mi`/`m1`–`m5` (Mac), or the row context menu.
- **Defer:** press `d` (or `⌘D`) on Mac to open the defer picker. It takes presets *and*
  natural language — `tomorrow`, `+3d`, `+1w`, `+1m`, a weekday name (`mon`,
  `tue`, …), or `weekend`. On iOS, swipe → **Defer**.
- **Delete:** the `Delete` key (Mac), swipe-to-delete with an undo toast (iOS).
- **Undo:** `u` or `⌘Z` — a snapshot stack, not a single level.
- **Reorder:** `Shift+J`/`Shift+K` (Mac) to swap within a group; drag-to-reorder
  (iOS). Order syncs across devices.

### List modes & filters

Tap the mode chip in the list header to cycle through three views:

- **`todo`** *(default)* — open, non-deferred tasks only.
- **`next`** — just the single top task of the current list, for heads-down focus.
- **`all`** — everything, including completed and deferred tasks.

On Mac you can also toggle the two filters independently: `fd` shows/hides
**done**, `fs` shows/hides **deferred**. Tap a context chip (or filter from the
sidebar) to scope the view to one `@context` across all projects; `Esc` clears
the filter.

### Subtasks (nesting)

Indent the selected task with `Tab` to make it a child of the task above it;
`Shift+Tab` outdents. Press `z` to collapse/expand a parent's subtree. Nesting
is stored as a `parent` pointer on the task, so it survives sync.

### Comments

Every task has an append-only comment thread (open the inspector to read/post).
Comments are the conversation layer — between you on two devices, between
collaborators on a shared list, and between you and Claude. They're append-only
on purpose: no "who deleted that?" ambiguity across devices.

### Voice capture

Tap the mic (iOS) or press `⌘⇧V` (Mac) to dictate a task. Transcription runs
**entirely on-device** via Apple's Speech framework
(`requiresOnDeviceRecognition: true`) — audio never leaves the device. Spoken
keywords like *"today"* or *"phone"* auto-tokenize into the same chips the
quick-add parser produces.

### Themes

Four built-in themes — **Tokyo Night, Catppuccin, Gruvbox, Ubuntu** — swap
instantly with no relaunch (Settings, or the command palette).

---

## Keyboard control (Mac)

todarchy is built for the keyboard. The main window uses vim-style bindings,
including two-key leader sequences (`gg`, `dd`, `g1`, `mi`, …) with a 0.6s
window.

**Navigation**

| Key | Action |
|-----|--------|
| `j` / `↓` | Next task |
| `k` / `↑` | Previous task |
| `gg` | First task |
| `G` | Last task |
| `←` / `→` | Previous / next list |
| `0` or `gi` | Jump to inbox |
| `1`–`5` or `g1`–`g5` | Jump to list N |

**Editing the selected task**

| Key | Action |
|-----|--------|
| `x` / `Space` | Toggle complete |
| `a` / `o` / `O` / `Return` | Capture a new task |
| `e` | Edit title inline |
| `d` | Defer (opens picker) |
| `Delete` | Delete |
| `u` | Undo |
| `Tab` / `Shift+Tab` | Indent / outdent (subtask) |
| `z` | Collapse / expand subtree |
| `Shift+J` / `Shift+K` | Move task down / up |
| `mi` / `m1`–`m5` | Move task to list N |

**View, search, commands**

| Key | Action |
|-----|--------|
| `fd` | Toggle show-done |
| `fs` | Toggle show-deferred |
| `Esc` | Clear context filter |
| `i` | Toggle inspector |
| `gn` | Manage projects |
| `/` | Search |
| `:` or `?` | Command palette |

**Menu & global shortcuts (with ⌘)**

| Shortcut | Action |
|----------|--------|
| `⌘N` | New task |
| `⌘D` | Defer (opens picker) |
| `⌘⇧V` | New task by voice |
| `⌘K` | Command palette |
| `⌘F` | Search |
| `⌘R` | Sync now |
| `⌘Z` | Undo |
| `⌥⌘I` | Toggle inspector |
| `⌥Space` | Global quick-capture (system-wide) |

---

## Syncing across devices

todarchy keeps one Automerge document. Sync is just a matter of getting that
document's bytes to your other devices; Automerge merges concurrent edits
without conflicts. There are three modes, picked in **Settings → Sync**. The
in-memory document survives switching between them.

### Local-only

Default. The document lives in the app's Application Support container and never
leaves the device.

### Folder sync

Point todarchy at a folder your existing file-sync daemon already covers
(Dropbox, an iCloud Drive folder, `~/Syncthing/`, …):

1. On device A: **Settings → Sync → Pick folder…** → choose the synced folder.
2. On device B: same thing, same folder. The first launch adopts the existing
   `tasks.automerge` verbatim; edits merge from there.
3. No server, no account — the file on disk is the source of truth.

Conflict copies the sync daemon leaves behind (`tasks 2.automerge`,
`…conflicted copy….automerge`, `…sync-conflict-….automerge`) get detected,
merged, and cleaned up automatically.

### Server sync (self-hostable relay)

For people who'd rather not route through a file-sync product, todarchy can push
the document to a small **self-hostable relay server**. The server is a dumb,
opaque blob store addressed by document id — it never sees plaintext (the client
encrypts shared-project blobs with ChaCha20-Poly1305 before upload, and the main
doc is mirrored as-is). The full server spec lives in
[`TODARCHY_SERVER_PROMPT.md`](TODARCHY_SERVER_PROMPT.md).

To use it: **Settings → Sync → Server**, enter the relay's base URL and a
**main-doc id**. Share the *same* main-doc id across your devices to link them.
The local file stays the document-of-record; the server is a mirror that the app
pulls on a ~10s foreground poll and pushes to after each save. The "always
overwrite" semantics mean writes are never surrendered — peer changes converge on
the next pull because the CRDT makes every merge idempotent.

---

## Sharing lists with other people

Beyond syncing *your own* devices, you can share an individual project with
**other people**, end-to-end encrypted.

**How it works**

- Promoting a project to *shared* generates a fresh 256-bit symmetric key and
  moves that project's tasks into a separate encrypted file
  (`shared_<projectId>.automerge.enc`) alongside the main document. Collaborators
  sync that encrypted file the same way you sync everything else (folder or
  server). **The transport never sees plaintext.**
- You hand out access with a **share link**:

  ```
  todarchy://share/<projectId>#k=<base64url-key>
  ```

  The key rides in the URL **fragment** (`#k=…`) on purpose — fragments are never
  sent to HTTP servers, so even a future "open in todarchy" web redirect can't
  leak keys into server logs. Opening the link on a device with todarchy
  installed joins the shared project.

**Setting it up**

1. **Set a sync passphrase** in Settings first. This derives a master key
   (Argon2) that encrypts a per-user keychain of share keys, so your *own* other
   devices automatically learn the keys for lists you've shared — without you
   re-opening each link on every device. Sharing still works locally without a
   passphrase, but keys won't propagate to your other devices.
2. **Share a project:** project context menu → *Share* → send the generated link
   to your collaborator.
3. **Accept a link:** open it (or paste it into the accept UI). todarchy stores
   the key, adds the project, and pulls the encrypted file when the transport
   delivers it.
4. **Leave a shared project:** drops it locally and forgets the key, without
   tombstoning the tasks for everyone else. (Deleting a project you *own* is
   different — that removes it and its tasks for all participants.)

The inbox can't be shared.

---

## AI access (Claude / MCP)

todarchy ships a small **MCP server** (`todarchy-mcp`) that exposes your tasks to
Claude or any MCP-compatible client over stdio (JSON-RPC 2.0,
protocol `2024-11-05`).

**Access is opt-in per project.** The server only ever sees projects where you've
flipped **"Allow Claude access"** on the project's context menu. It reads that
flag fresh on every call, so revoking access takes effect immediately. Projects
without the flag are completely invisible to the server.

### Tools

| Tool | What it does |
|------|--------------|
| `list_tasks` | List tasks across Claude-accessible projects. Filter by `status` (`open`/`done`/`all`) and optional `project` name. |
| `get_task` | Fetch one task by id, including its markdown body and full comment thread. |
| `add_task` | Create a task in a named, accessible project. |
| `complete_task` | Mark a task done. |
| `add_comment` | Append a comment to a task (author defaults to "Claude"). |
| `set_task_body` | Replace a task's markdown body — the canonical long-form field for plans, specs, deliverables. Comments are untouched. |

The intended workflow: Claude works in a task's **body** (the deliverable) and
talks to you in its **comments** (the conversation).

### Setup

1. Build the `todarchy-mcp` scheme. Locate the built binary (it's a command-line
   tool; `xcodebuild -scheme todarchy-mcp -destination 'platform=macOS' build`
   then look under DerivedData, or copy it somewhere stable).
2. Register it with your MCP client. For Claude Desktop, in
   `claude_desktop_config.json`:

   ```json
   {
     "mcpServers": {
       "todarchy": {
         "command": "/path/to/todarchy-mcp",
         "env": {
           "TODARCHY_MCP_AUTHOR": "Claude"
         }
       }
     }
   }
   ```

3. In the app, enable **Allow Claude access** on the projects you want exposed.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TODARCHY_FILE_PATH` | the sandboxed app container's `tasks.automerge` | Path to the document the server reads/writes. |
| `TODARCHY_MCP_AUTHOR` | `Claude` | Name stamped on comments the server posts. |
| `TODARCHY_MCP_READ_ONLY` | unset | Set to `1` to refuse all mutations — useful while onboarding, so Claude can read before you grant writes. |

The server reads and writes the *same* `tasks.automerge` the app uses, going
through the same Automerge merge path — so the running app picks up Claude's
changes (and vice versa) the moment the file changes.

---

## Architecture

- **`todarchy/AutomergeStore.swift`** — wraps
  [`automerge-swift`](https://github.com/automerge/automerge-swift) behind a
  serial queue; every Document op goes through one thread to avoid
  concurrent-init panics in the Rust core. Writes are **upsert-only** (never
  tombstone a key just because it's missing from a local snapshot).
- **`todarchy/Persistence.swift`** — debounced on-disk writes, conflict-copy
  ingestion, server push/pull, and poison-recovery: if a Rust panic leaves a
  mutex poisoned, it rebuilds the document from the last-good disk bytes and
  retries.
- **`todarchy/Store.swift`** — the SwiftUI-facing store: `tasks`, `projects`,
  selection, filters, undo (a snapshot stack).
- **`todarchy/Shared/VoiceCapture.swift`** — on-device transcription plus a
  mic-level tap for the equalizer visualization.
- **`todarchy-mcp/`** — the standalone MCP server (config, JSON-RPC framing,
  tool handlers, and a one-shot document wrapper).

### Schema

The document has a fixed shape, matching the Linux companion byte-for-byte:

```
{
  version  : Int64 = 1,
  contexts : List<String>,
  tasks    : Map<id, Task>,     // keyed by id, NOT a list
  projects : Map<id, Project>,
}
```

Tasks and projects live in a `Map<id, …>` so concurrent inserts on two devices
land at different keys and **both** survive the merge — a list would have both
inserts target the same index and Automerge would drop one. Task `id` and
`parent` are **`String`, not `UUID`**: cross-platform clients (the Linux app
ships short base36 ids) send non-UUID values, and strict UUID parsing would
silently drop those tasks from the UI.

---

## Testing

```bash
xcodebuild -project todarchy.xcodeproj -scheme todarchy \
  -destination 'platform=macOS' test
```

~480 tests covering the store, quick-add parser, sync logic, key router,
sharing/crypto, the MCP document path, and the Automerge shape invariants.

---

## Contributing

Contributions welcome. A few conventions:

- `generate_project.rb` is the source of truth for project settings. Add a Swift
  file, then re-run the script — don't hand-edit `project.pbxproj`.
- Don't commit a `DEVELOPMENT_TEAM` value — Xcode injects yours when you sign for
  a device. Re-run `ruby generate_project.rb` before pushing to wipe it.
- Local tooling state (`.claude/`, `.vscode/`, `.idea/`, `xcuserdata/`) is
  gitignored.

## License

MIT — see [LICENSE](LICENSE).
