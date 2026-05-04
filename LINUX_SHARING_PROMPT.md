# Prompt — Implement encrypted per-project sharing in todarchy-linux

Paste this into a new Claude Code session against the todarchy-linux repo.
All of this is already implemented and shipped in the Swift apps (Mac /
iOS / iPad). Your job is to match it so Linux can read, write, share,
and accept shared projects — with **byte-for-byte wire compatibility**
against what Swift writes.

## Context

Up to now, all todarchy clients (Swift + Linux) share a single
`tasks.automerge` file in a user-picked sync folder (Dropbox, iCloud
Drive, Syncthing, a local folder — doesn't matter, it's just a file).
That's great for one user across their own devices, but bad for
collaboration: to share a single project with a second user, you'd
have to share the whole file, leaking every other list.

The Swift apps now ship a sharing model that keeps the "just files on
disk" virtue but adds per-project encrypted files, each with its own
symmetric key. The key is shared out-of-band via a URL with the key in
the fragment (never hits a server). Any transport that can move
opaque bytes — a shared Dropbox folder today, a dumb relay server
later — works without changes.

**Your task:** implement the exact same format + behaviors in the
Linux Tauri app so both sides can read/write each other's shared
files seamlessly.

---

## Wire format — lock these down first

### 1. File naming

Shared project files live **as siblings of `tasks.automerge`** in the
sync folder:

```
<sync-folder>/tasks.automerge                       ← personal doc
<sync-folder>/shared_<projectId>.automerge.enc      ← one per shared project
```

`<projectId>` is the project's id verbatim — do not URL-encode or
transform it. New ids generated Swift-side are lowercased UUID strings
(e.g. `p_abc12345` prefix + random). Linux-side ids may be anything;
preserve whatever you find.

### 2. CryptoBox envelope

Every `shared_*.automerge.enc` file has this byte layout:

```
┌────────┬──────┬────────┬──────────────────┬──────────┐
│ "TDAR" │ ver  │ nonce  │   ciphertext     │ auth tag │
│  4 B   │  1 B │  12 B  │     variable     │   16 B   │
└────────┴──────┴────────┴──────────────────┴──────────┘
```

- **Magic**: ASCII bytes `0x54 0x44 0x41 0x52` ("TDAR"). Reject files
  that don't start with this so a directory scan can skip junk.
- **Version**: one byte. Current version is `0x01`. Reject unknown
  versions (don't try to decrypt them).
- **Nonce**: 12 random bytes, fresh per encrypt. **Critical**: never
  reuse a (key, nonce) pair with ChaCha20-Poly1305 — confidentiality
  is destroyed under nonce reuse. Use a CSPRNG.
- **Ciphertext**: variable length; the plaintext is **the full
  Automerge doc bytes** (exactly what `Automerge.save()` returns).
- **Auth tag**: 16 bytes appended by the AEAD.

Total envelope overhead is 33 bytes per file.

### 3. Cipher

**ChaCha20-Poly1305** (IETF variant, 96-bit nonce, 128-bit tag).

- Key size: **256 bits** (32 bytes). Generated with `getrandom` or
  equivalent CSPRNG.
- Reference: RFC 8439.
- Rust: the `chacha20poly1305` crate (use `ChaCha20Poly1305`, not
  `XChaCha20Poly1305` — Swift is using the 96-bit nonce variant).

### 4. Share link format

```
todarchy://share/<projectId>#k=<base64url-key>
```

- **Scheme**: `todarchy` (lowercase).
- **Host**: `share`.
- **Path**: `/<projectId>`. Percent-encode the id for URL safety; the
  decoded form is what you key storage/filesystem under.
- **Fragment** (after `#`): `k=<base64url-encoded-key>`. Fragments
  never reach HTTP servers — if we later add an `https://todarchy.app/`
  landing page that redirects into the custom scheme, keys still stay
  client-side. Don't move the key to the query.
- **base64url**: RFC 4648 §5. Alphabet `A-Z a-z 0-9 - _`, no `+`, `/`,
  or `=` padding. Length of encoded 32-byte key is 43 chars.
- **Forward compat**: the fragment is a `&`-joined list of `key=value`
  pairs. Unknown keys must be **ignored**, not rejected. Future
  versions may add things like `&v=2` or `&exp=<unix-ms>`.

Swift encoder emits just `k=<value>`. Decoder accepts any subset that
includes `k=`.

---

## Automerge schema — unchanged

Shared project files use the **exact same Automerge schema** as
`tasks.automerge`:

```
{
  version  : Int64 = 1,
  contexts : List<String>,
  tasks    : Map<id, Task>,
  projects : Map<id, Project>,
}
```

In a shared file, `tasks` contains just that one project's tasks, and
`projects` contains one entry (the shared project's own metadata).
`contexts` is typically empty or a seed list — context state is kept
in the main doc.

**Authoritative copy of the project's metadata is the shared file.**
If the main doc has a stub entry for a shared project, and the shared
file has a different name/color, the shared file wins.

---

## ProjectItem — new `isShared` field

```
struct ProjectItem {
  id: String,
  name: String,
  icon: String,
  accent: String,       // CSS-hex "#7aa2f7"
  isInbox: bool = false,
  isShared: bool = false,   // ← new
}
```

- **Decoder**: accept missing field, default `false`. Old docs without
  the field continue to work.
- **Encoder**: only emit the field when `true`. Keeps older files
  byte-stable.

A project is "shared" iff:
- Its `isShared` in the main doc is `true`, AND
- A `shared_<projectId>.automerge.enc` file exists in the sync folder,
  AND
- This device has the key for that project.

If any are missing, the project is either: not shared here, shared but
not yet joined on this device, or flagged-shared but the file hasn't
synced yet (show a "joining…" or empty state in the UI).

---

## Id type — MUST be String, not a strict UUID

This is a trap we already fell into. Swift's `UUID.init(uuidString:)`
returns `nil` for non-UUID strings (like the base36 ids Linux has
historically written), and that caused entire tasks to silently
disappear from the Swift UI — debugged for hours before finding it.

- Treat `task.id`, `task.parent`, and `project.id` as **opaque
  strings**. Never strict-parse as UUID in decode paths.
- Log + skip + preserve unknown string ids rather than dropping them.
- When generating new ids, lowercased UUIDs are fine, but accept any
  string shape on read.
- Swift-side log any skipped entry via `os_log` with raw id + which
  field was missing. Do the equivalent with `tracing` or `log` on
  Linux so cross-platform regressions are grep-able.

---

## Key storage — libsecret / secret-service

On Swift we use the Keychain with `kSecAttrSynchronizable = YES` so
keys follow the user across their own devices via iCloud Keychain.
Linux doesn't have that by default; the right primitive is
**libsecret** (a.k.a. secret-service, backed by gnome-keyring / KWallet /
kde-wallet depending on DE).

The Rust [`keyring`](https://crates.io/crates/keyring) crate wraps
it. Use:

- **Service name**: `com.todarchy.app.shared-keys`
- **Account**: `<projectId>`
- **Secret**: raw 32 bytes of the key

Matches the Swift namespace exactly; if a Linux + Swift install happen
to run on the same physical hardware (unusual but possible), they use
the same keyring service string.

Key lifecycle:

- **On share**: generate a key, store it before writing any ciphertext.
- **On accept**: decode the link, store the key, then write the
  project stub into the main doc.
- **On "leave project" (local)**: delete the key; optionally delete
  the encrypted file. Don't tombstone inside the doc — other users
  keep their copies.

---

## Behaviors — 1:1 with the Swift side

### A. `promote_to_shared(project_id)`

1. Read the project's current tasks from the main doc.
2. Generate a fresh 256-bit key.
3. Store the key under `project_id` in the keyring.
4. Create a new empty Automerge doc, upsert the project (with
   `isShared = true`) and all its tasks.
5. `doc.save()`, seal bytes with CryptoBox, write atomically to
   `<folder>/shared_<project_id>.automerge.enc`.
6. In the main doc: flag the project `isShared = true`, **tombstone
   every task that lived in it** (they've moved to the encrypted file).
7. Return the share link.

### B. `accept_share_link(url)`

1. Decode the URL → `(project_id, key)` — reject `wrongScheme` /
   malformed / bad key.
2. Save the key in the keyring under `project_id`.
3. If `shared_<project_id>.automerge.enc` is already present (Dropbox
   pre-synced), decrypt and extract the project metadata.
4. Otherwise add a placeholder project stub to the main doc (name:
   `"shared project"`, icon: whatever Linux uses for "person.2"), with
   `isShared = true`. When sync delivers the file, the shared-file's
   metadata overrides the stub on next load.
5. Idempotent: re-accepting the same link must be a no-op if already
   joined.

### C. Load (the union read)

When rendering tasks for the UI:

1. Snapshot the main doc → `main_snapshot.tasks + main_snapshot.projects`.
2. For every project in `main_snapshot.projects` with `isShared =
   true`, look up its key.
3. If we have the key AND the shared file exists: open it, decrypt,
   snapshot → **replace** any tasks in `main_snapshot.tasks` matching
   that project id with the shared file's tasks, and **overwrite** the
   project entry with the shared file's (authoritative) metadata.
4. Display the union.

### D. Save (split writes)

When persisting changes:

1. Partition tasks in the current UI snapshot by whether their
   `task.list` matches an opened shared project id:
   - `main_tasks` → upsert into main doc.
   - `shared_tasks[project_id]` → upsert into that project's
     `PerProjectStore`.
2. Partition deletions by the task's **former** list id (you must
   capture this at delete time, before the task is removed from the
   UI state — once it's gone, you can't recover which doc it lived in).
3. Apply main-doc writes, save + atomically write `tasks.automerge`.
4. For each opened shared store: apply its partition, seal, write
   atomically to `shared_<id>.automerge.enc`.

### E. External merge (refresh)

When the file watcher reports a change or the user pulls-to-refresh:

1. Re-read the main doc; merge into in-memory main Automerge instance.
2. For each opened shared store: re-read its file, decrypt, merge into
   in-memory per-project Automerge instance.
3. Ingest conflict copies (next section).

### F. Conflict ingestion

Sync daemons produce sibling files when they can't reconcile concurrent
writes. Per shared project, scan for files matching all three shapes:

- Dropbox: `shared_<id> (HOST's conflicted copy 2026-04-20).automerge.enc`
- iCloud: `shared_<id> 2.automerge.enc`
- Syncthing: `shared_<id>.sync-conflict-20260420-123456-XXXX.automerge.enc`

Match rule (we verified this in tests — don't relax it):

```
filename.starts_with("shared_" + project_id)
&& filename.ends_with(".automerge.enc")
&& filename != canonical_name
&& the character immediately after "shared_" + project_id is NOT
   alphanumeric or underscore
```

That last rule prevents a project with id `p_abc_extra` from being
absorbed into a store keyed `p_abc`.

For each match:

1. Read bytes.
2. Try to decrypt with our key. If it fails (wrong key, garbage, not
   our envelope), **leave the file on disk**. Don't delete bytes you
   can't authenticate.
3. If decryption succeeds, merge into the live doc.
4. Only then delete the conflict file.

Swift-side uses the same logic for the main `tasks.automerge` — reuse
that code for the per-shared-file path.

---

## URL scheme registration

Register `todarchy://` as a handled URL scheme in the Tauri
application's `tauri.conf.json`:

```json
{
  "tauri": {
    "bundle": {
      "identifier": "app.todarchy.linux",
      "deepLinkProtocols": ["todarchy"]
    }
  }
}
```

On Linux this is ultimately a `.desktop` file with `MimeType=x-scheme-handler/todarchy`.
When a `todarchy://...` URL is opened elsewhere, your app gets invoked
with the URL as argv or through Tauri's deep-link plugin. Route it to
`accept_share_link`.

---

## Testing expectations

Mirror the coverage the Swift side ships with. Key invariants the
tests pin down:

1. **Envelope round-trip** — encrypt + decrypt recovers plaintext.
2. **Fresh nonce per seal** — same key + same plaintext produce
   different ciphertexts each time.
3. **Tamper detection** — flipping any byte in ciphertext OR tag
   causes decryption to fail.
4. **Wrong key fails cleanly** — decrypt with a different key returns
   an error, doesn't panic or return garbage.
5. **base64url encoding** — keys in share links contain no `+`, `/`,
   or `=` characters.
6. **Forward-compat fragments** — decoder accepts `#k=X&v=2&exp=123`
   and only extracts `k`.
7. **Share link invariants**:
   - scheme must be `todarchy`
   - host must be `share`
   - path must be non-empty after trimming slashes
   - fragment must contain `k=<valid-base64url-32-bytes>`
8. **Two-device merge** — A writes "milk", B writes "bread", B's bytes
   merged into A → A sees both.
9. **Conflict shapes** — each of the three filename patterns above
   gets absorbed; afterwards the conflict file is gone.
10. **Id-prefix collision** — `shared_p_abc_extra.automerge.enc`
    doesn't pollute a store for `p_abc`.
11. **Undecryptable conflict left on disk** — a conflict file
    encrypted with the wrong key survives the sweep.
12. **`isShared` decode backward compat** — projects from a doc that
    predates the field decode with `isShared = false`.

If Rust test infrastructure has a keyring integration seam, mock it
the same way the Swift tests do — production uses libsecret, tests use
an in-memory implementation so CI doesn't fail without a session bus.

---

## Interop sanity check

Once your implementation is done, run this end-to-end:

1. **Swift creates → Linux reads**. On Mac/iPhone, promote a project;
   wait for the encrypted file to reach your Linux Dropbox/Syncthing
   folder; paste the share link into your Linux app; verify the tasks
   show up with correct title/list/accent/etc.
2. **Linux creates → Swift reads**. Reverse.
3. **Concurrent edits**. Both sides edit while offline; reconnect; the
   sync daemon produces a conflict copy on one side; verify it's
   absorbed on next tick, no tasks lost.
4. **Delete on one side**. Delete a task on Linux; verify it
   disappears on Swift after sync. Tombstone must be a real Automerge
   delete, not just an array splice — otherwise the Swift side will
   resurrect it on next merge.

---

## What's explicitly out of scope

- **Cross-device sync of keys via something iCloud-Keychain-like** —
  Linux users paste the link manually on each of their own devices,
  same as the collaborator flow. Consider a future QR-code export
  mechanism.
- **Server relay**. This spec assumes the bytes travel via a shared
  filesystem. A later version may add an HTTP/WebSocket relay as an
  alternative transport, but the envelope format + share link format
  stay identical; only the byte-moving layer changes.
- **Key rotation / revocation**. Once shared, the key is shared
  forever. Rotating = create a new project, migrate tasks, un-share
  the old one. Fine for now.

---

## Checklist

- [ ] CryptoBox envelope encode + decode (4 tests minimum).
- [ ] ShareLink encode + decode with base64url key in fragment.
- [ ] Per-project store: load, save, merge, refresh-from-disk,
      conflict ingestion.
- [ ] ProjectItem `isShared` Codable-compatible add.
- [ ] Main-doc coordinator: load unions, save splits, delete routes.
- [ ] libsecret-backed key storage with in-memory test impl.
- [ ] URL scheme registration in `tauri.conf.json` + deep-link handler.
- [ ] "Share" UI on project list: generate link → copy to clipboard.
- [ ] Accept flow that jumps to the newly-joined project.
- [ ] Visual indicator (small group icon) on shared projects.
- [ ] All Swift-side interop test cases pass.

Happy to answer questions as they come up — the Swift implementation is
the reference and is already in production.
