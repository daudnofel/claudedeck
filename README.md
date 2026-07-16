# ClaudeDeck

A tiny native macOS menu bar app that shows every running **Claude Code**
session, its live working/idle status, and lets you jump to any session's
window — or sweep all your Terminal windows into a corner with one click.

Running five or six Claude Code sessions in Terminal.app buries the desktop in
windows, with no at-a-glance way to see which session is actively working
versus done and waiting for review. ClaudeDeck fixes that.

```
┌─────────────────────────────┐
│ Claude Sessions             │
│ 🟢 ai-sidebar               │  green dot pulses while Claude works
│    Build macOS dock widget  │  live task subtitle from the window title
│ ⚪ api-refactor             │  row click → focus that window + tab
│ ⚪ blog-fixes               │
├─────────────────────────────┤
│ [Tuck all] [Collapse all]   │
│ [Restore all]               │
│ ☐ Show Dock window          │
│ Quit ClaudeDeck             │
└─────────────────────────────┘
```

- **Tuck all** — every Terminal window shrinks into a tidy grid of small tiles
  in the bottom-right corner.
- **Collapse all** — every window shrinks to its minimum size and piles into a
  card-deck stack in the corner (near-zero screen space).
- **Restore all** — everything springs back to its original position and size.
- **Click a session** — its window returns to its pre-tuck bounds (or a
  comfortable centered size if none is known), comes to the front, and the
  right tab is selected.

## How it works

No hooks, no config, no daemon — it reads signals the OS already exposes,
polling every 2 seconds off the main thread:

- **Discovery.** `ps -axo pid=,%cpu=,tty=,command=` enumerates processes;
  ClaudeDeck keeps rows whose executable basename is `claude`, that have a real
  controlling tty, and that are not helper subcommands (`bg-pty-host`,
  `bg-spare`, `daemon`). Wrappers such as `caffeinate -is claude …` are
  filtered out, and one session is kept per tty. One batched
  `lsof -a -p <pids> -d cwd` call resolves every session's working directory;
  its last path component becomes the session name.
- **Status.** Claude Code animates a spinner glyph in the terminal title while
  it works (braille characters like `⠂`) and shows `✳` when idle/awaiting
  input. ClaudeDeck reads that glyph from the matched Terminal window title —
  authoritative, instant, and free. When no glyph is readable (renamed window,
  no task yet), it falls back to transcript freshness: the newest `.jsonl`
  under `~/.claude/projects/<encoded-cwd>/` modified within 30 s counts as
  working.
- **Windows.** Terminal.app is scriptable, so ClaudeDeck maps each session's
  tty to a Terminal window/tab via AppleScript, reads the live task from the
  window title, focuses windows, and tucks/restores window bounds. Original
  window positions persist across app restarts. No Accessibility permission is
  needed — only Automation.

## Build & run

Requires macOS 13+ and a Swift toolchain (Xcode command line tools).

```bash
# Compile
swift build

# Build a signed, double-clickable app bundle at build/ClaudeDeck.app
bash scripts/make-app.sh
open build/ClaudeDeck.app
```

ClaudeDeck runs as a menu bar item (SF Symbol `rectangle.stack`, badged with
the number of working sessions). Toggle **Show Dock window** to also get a
regular window with the same list.

## Permissions

On first use, macOS asks to let ClaudeDeck control **Terminal.app**
(Automation). Approve it once. If you decline, the app shows an inline hint
with a button that opens
**System Settings → Privacy & Security → Automation**. That is the only
permission ClaudeDeck needs.

## Known limitations

- Terminal reports only the **selected tab's** title per window, so with
  multiple Claude tabs in one window, non-selected tabs use the weaker
  transcript-freshness fallback. One window per session works perfectly.
- Two sessions running in the **same working directory** share one transcript
  dir, so the fallback signal can't tell them apart (the title glyph still
  can).
- Terminal.app only for now. iTerm2 and editor terminals are natural follow-ups.

## Debugging

Launch with `CLAUDEDECK_DEBUG=1` to write a trace of discovery, status, and
AppleScript activity to `/tmp/claudedeck-debug.txt`.

## License

[MIT](LICENSE)
