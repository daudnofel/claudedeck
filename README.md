# ClaudeDeck

A tiny native macOS menu bar app that shows every running **Claude Code**
session, its live status, and lets you jump to one window or tuck all your
Terminal windows into a neat corner stack.

Running five or six Claude Code sessions in Terminal.app buries the desktop in
windows, with no at-a-glance way to see which session is actively working versus
done and waiting for review. ClaudeDeck fixes that.

![screenshot placeholder](docs/screenshot.png)

```
┌─────────────────────────────┐
│ Claude Sessions             │
│ 🟢 ai-sidebar               │  green dot pulses while working
│    Build macOS dock widget  │  live task subtitle from the window title
│ ⚪ api-refactor             │  row click → focus that window + tab
│ ⚪ blog-fixes               │
├─────────────────────────────┤
│ [ Tuck all ] [ Restore all ]│
│ ☐ Show Dock window          │
│ Quit ClaudeDeck             │
└─────────────────────────────┘
```

## How it works

No hooks, no config, no daemon — it reads the same signals the OS already
exposes, polling every 2 seconds:

- **Discovery.** `ps -axo pid=,tty=,command=` enumerates processes; ClaudeDeck
  keeps rows whose executable basename is `claude`, that have a real controlling
  tty, and that are not helper subcommands (`bg-pty-host`, `bg-spare`,
  `daemon`). Wrappers such as `caffeinate -is claude …` are filtered out, and
  one session is kept per tty.
- **Working directory.** `lsof -a -p <pid> -d cwd -Fn` resolves each session's
  cwd; its last path component becomes the session name.
- **Status.** Claude Code appends to a transcript `.jsonl` under
  `~/.claude/projects/<encoded-cwd>/` while it works (the cwd is encoded by
  replacing every non-`[A-Za-z0-9]` character with `-`). If the newest `.jsonl`
  there was modified within the last 5 seconds the session is **working**
  (pulsing green); otherwise **idle** (gray).
- **Windows.** Terminal.app is scriptable, so ClaudeDeck uses AppleScript to map
  each session's tty to a Terminal window/tab, read the live task from the window
  title, focus a window, and tuck/restore window bounds. No Accessibility
  permission is needed — only Automation.

## Build & run

Requires macOS 13+ and a Swift toolchain (Xcode command line tools).

```bash
# Compile
swift build

# Build a signed, double-clickable app bundle at build/ClaudeDeck.app
bash scripts/make-app.sh
open build/ClaudeDeck.app
```

ClaudeDeck runs as a menu bar item (SF Symbol `rectangle.stack`, badged with the
number of working sessions). Toggle **Show Dock window** to also get a regular
window with the same list.

## Permissions

On first use of Focus / Tuck / Restore, macOS asks to let ClaudeDeck control
**Terminal.app** (Automation). Approve it once. If you decline, the app shows an
inline hint with a button that opens
**System Settings → Privacy & Security → Automation**. That is the only
permission ClaudeDeck needs.

## Known limitation

Status is derived from the transcript directory, which is keyed by working
directory. **Two sessions running in the same cwd share one transcript dir and
therefore show the same status.** This is acceptable for v1.

## License

MIT.
