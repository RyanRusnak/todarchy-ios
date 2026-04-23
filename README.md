# todarchy

A keyboard-first, GTD-light todo app for Mac, iPhone, and iPad. Built with
SwiftUI. Syncs across devices (and with the [Linux companion
app](https://github.com/RyanRusnak/todarchy-linux)) through a shared
Automerge CRDT document stored in any file-sync folder you already use —
Dropbox, iCloud Drive, Syncthing, or a plain folder on disk.

No server. No account. No cloud round-trip. Your tasks live in one
`tasks.automerge` file on disk.

## Why it exists

GTD apps either want a subscription or force a workflow. This one is
opinionated about the **ergonomics** (type `a`, capture a task, move on)
but neutral about **where your data lives** — it's a file, put it
wherever. Works offline; syncs when the file syncs.

## Features

- **Vim-style keyboard control on Mac.** `j/k` to move, `x` to complete,
  `s` to defer, `d` to delete, `e` to edit, `/` to search, `⌘K` palette,
  `⌘⇧V` voice capture. `g1`/`g2`/… jump between lists.
- **Three list modes** — `todo` (default), `next` (just the top task for
  focus), `all` (includes completed + deferred). One tap to cycle.
- **Context filters** (`@work`, `@home`, `@phone`, …) and due buckets
  (`!today`, `!tomorrow`, `!week`).
- **Quick-add parser** — type `call mom @phone !today /remember to ask
  about flights` and the chips parse automatically.
- **Voice capture** — tap the mic (iOS) or press `⌘⇧V` (Mac). Apple's
  on-device Speech framework — audio never leaves the device. Spoken
  `"today"`, `"phone"`, etc. auto-tokenize into the chip form.
- **Drag-to-reorder** on iOS, `Shift+J/K` swap on Mac. Reorders sync
  across devices via `pos` mutations.
- **Swipe-to-delete** with an undo toast on iOS.
- **Cross-device sync** over any file-sync folder. Automerge handles
  concurrent edits; conflict copies from the sync daemon get absorbed
  automatically.
- **Four themes** — Tokyo Night, Catppuccin, Gruvbox, Ubuntu. Swap
  instantly, no relaunch.

## Getting started

### Requirements

- macOS 14+ and/or iOS 17+
- Xcode 16+
- Ruby (for the project generator — only needed if you change the file
  layout)

### Build

```bash
git clone <this repo>
cd todarchy
ruby generate_project.rb     # regenerates todarchy.xcodeproj
open todarchy.xcodeproj
```

In Xcode, select your development team for both targets (the repo ships
with an empty team ID so you don't pick up someone else's signing
identity). Then build + run — Mac destination for macOS, any iOS
simulator or device for iOS.

### Setting up sync

1. On any device: **Settings → Sync → Pick folder…** → point at a folder
   your file-sync daemon already covers (Dropbox, iCloud Drive folder,
   `~/Syncthing/`, etc.).
2. On the next device: same thing — point at the same folder. The first
   launch adopts the existing `tasks.automerge` verbatim; your edits
   merge into it from there.
3. No server configuration, no account. The file on disk is the source
   of truth.

## Architecture notes

- **`todarchy/AutomergeStore.swift`** — wraps
  [`automerge-swift`](https://github.com/automerge/automerge-swift)
  behind a serial queue; all Document ops go through one thread to avoid
  concurrent-init panics in the Rust core.
- **`todarchy/Persistence.swift`** — debounced on-disk writes +
  poison-recovery: if Rust panics leave a mutex poisoned, rebuild the
  doc from the last-good disk bytes and retry.
- **`todarchy/Store.swift`** — the SwiftUI-facing store. Exposes
  `tasks`, `projects`, selection, filters. Undo is a snapshot stack.
- **`todarchy/Shared/VoiceCapture.swift`** — live on-device transcription
  with `SFSpeechRecognizer(requiresOnDeviceRecognition: true)` plus a
  mic-level tap for the equalizer visualization.

## Schema

The Automerge doc has a fixed shape matching the Linux companion:

```
{
  version  : Int64 = 1,
  contexts : List<String>,
  tasks    : Map<id, Task>,     // keyed by id, NOT a list
  projects : Map<id, Project>,
}
```

Tasks/projects live in a `Map<id, …>` so concurrent inserts on two
devices land at different keys and both survive the merge. Task ids are
**`String`**, not UUID — cross-platform clients ship non-UUID ids and
strict parsing silently drops them from the UI.

## Testing

```bash
xcodebuild -project todarchy.xcodeproj -scheme todarchy \
  -destination 'platform=macOS' test
```

268 tests covering the store, parser, sync logic, key router, and the
Automerge shape invariants.

## Contributing

Contributions welcome. A few conventions:

- Ruby `generate_project.rb` is the source of truth for project
  settings. If you add a new Swift file, just re-run the script.
- Don't commit a `DEVELOPMENT_TEAM` value — Xcode auto-injects yours
  when you sign for device. Re-run `ruby generate_project.rb` before
  pushing to wipe it.
- Local tooling state (`.claude/`, `.vscode/`, `.idea/`, `xcuserdata/`)
  is gitignored.

## License

MIT — see [LICENSE](LICENSE).
