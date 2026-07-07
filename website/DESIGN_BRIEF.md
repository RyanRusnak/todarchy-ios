# todokase — Website Design Brief

A self-contained brief for building the marketing site (GitHub Pages). Everything
here is extracted verbatim from the app so the site matches it exactly. Hand this
file — plus `tokens.css`, `fonts/`, and `icon-1024.png` — to any designer/tool.

## What todokase is
A **free, keyboard-first todo app** for iOS, iPadOS, and macOS (SwiftUI, one
project → three destinations). Ported natively from a Linux desktop app
(Tauri + Rust + React). Syncs across devices, end-to-end encrypted sharing.
Ships with a macOS companion **CLI** for capturing tasks from the terminal.

**Positioning words:** keyboard-first · fast · minimal · developer-flavored ·
GTD-light · themeable · private/E2E-encrypted · native · terminal CLI.

**Voice:** lowercase, terse, technical, confident. The app name is always
lowercase: `todokase`. Mono type reinforces the "built by/for people who live in
a terminal" feel. Avoid productivity-guru fluff.

## Visual identity (the signature)
- **Type:** JetBrains Mono, *everywhere* — headings, body, UI. Shipped in `fonts/`.
  Fallback stack: `"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace`.
- **Borders:** 2px, visible (`--border-w`). Borders define structure, not shadows.
- **Radii:** 10px panels/cards, 8px buttons/chips, 4px tags. (`--radius*`)
- **Theme:** dark by default — **Tokyo Night**. The app ships 4 palettes
  (Tokyo Night, Catppuccin, Gruvbox, Ubuntu); all four are in `tokens.css` as
  `[data-theme]` blocks. A theme switcher on the site is very on-brand.
- **Layout in the app:** three-pane (sidebar / list / inspector) on Mac+iPad;
  command palette (⌘K-style); vim-mode navigation (j/k/x/d shortcuts).

## Color tokens — Tokyo Night (default; full set in `tokens.css`)
| Token | Hex | Use |
|---|---|---|
| `--bg` | `#1A1B26` | page background |
| `--bg-elev` | `#16171F` | recessed areas |
| `--bg-soft` | `#1F2030` | subtle raised fills |
| `--panel` | `#1F2335` | cards / panels |
| `--border` | `#2A2E42` | default 2px border |
| `--border-hi` | `#3B4261` | hover/active border |
| `--fg` | `#C0CAF5` | primary text |
| `--fg-dim` | `#9AA5CE` | secondary text |
| `--fg-mute` | `#565F89` | captions / hints |
| `--fg-faint` | `#3B4261` | disabled |
| `--accent` / `--blue` | `#7AA2F7` | primary accent, links, CTAs |
| `--accent2` / `--purple` | `#BB9AF7` | secondary accent |
| `--success` | `#9ECE6A` | done / positive (also "this week" green cues) |
| `--warn` | `#E0AF68` | "tomorrow" due chip |
| `--danger` | `#F7768E` | "today" due chip / destructive |
| `--cyan` | `#7DCFFF` | info |
| `--orange` | `#FF9E64` | tertiary highlight |

**Semantic mapping from the app** (reuse on the site for authenticity):
due **today = red** (`--danger`), **tomorrow = yellow** (`--warn`),
**this week = blue** (`--accent`). Done = `--success`. Contexts (`@home @work
@errands @phone @mac @read`) render as small `--radius-xs` tags.

## Type scale (`tokens.css`)
Base **14px** (matches app). `--fs-xs 11 · sm 12 · md 14 · lg 18 · xl 24 ·
2xl 34 · 3xl 48 (hero)`. Weights available: 400 / 500 / 600 / 700. Line-height
1.5, no letter-spacing (mono).

## Product facts for copy (GTD-light — don't overclaim)
- Lists: **inbox** (built-in) + user **projects** (seeded: work, home, wedding planning).
- **Contexts** as cross-cutting filters: `@home @work @errands @phone @mac @read`.
- **Due buckets** only: today / tomorrow / this week. *No arbitrary dates in v1.*
- **Defer** (hide until a time — defers to next morning), **done** (hide unless shown).
- Keyboard-first + command palette + vim navigation.
- Cross-device sync; end-to-end encrypted project sharing.
- **CLI** (macOS companion): `todokase add "…"`, `todokase list`, `todokase next`.
  Supports the same `@ctx !due /note` quick-add syntax; defaults to inbox, or
  `--project <name>`. Installed separately (e.g. Homebrew), not bundled in the app.
- **Do NOT** invent: recurrence, smart views, priority flags, arbitrary tags,
  Things/OmniFocus vocabulary. v1 is intentionally small.

## Assets in this folder
- `fonts/JetBrainsMono-{Regular,Medium,SemiBold,Bold}.ttf` — wired up in `tokens.css`.
- `icon-1024.png`, `icon-512.png` — app icon (logo / favicon / OG image source).
- `tokens.css` — drop-in variables, `@font-face`, and a base reset.
- `index.html` — a minimal, on-brand starter that renders on GitHub Pages today.

## Suggested sections for the site (small, single page)
1. Hero: name + one-line pitch + App Store / TestFlight badge + app screenshot.
2. Feature strip: keyboard-first · contexts · due buckets · themes · E2E sync · CLI.
3. A visual of the three-pane layout / command palette.
4. Theme switcher showcasing the 4 palettes (differentiator).
5. Footer: GitHub link, privacy note (E2E), platforms (iOS/iPadOS/macOS).

## GitHub Pages notes
- Serve this `website/` folder (Pages → deploy from `/website` on `main`, or move
  to `/docs`). It's plain static HTML/CSS — no build step.
- Real app screenshots aren't in the repo yet; capture from the running app (or
  the `design_handoff_apple_apps/*.html` prototypes) and add to `website/`.
