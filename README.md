# ClaudeDeck

A tiny native macOS menu bar app for people who run **many Claude Code
sessions at once**. It shows every session with live working/idle status,
jumps you to any session's window, sweeps your Terminal windows into a
corner, and can pause sessions (freeing memory) and resume them later with
full context.

Running five or six Claude Code sessions in Terminal.app buries the desktop
in windows, with no at-a-glance way to see which session is actively working,
which is waiting on a background task, and which is done and waiting for you.
ClaudeDeck fixes that — with **zero configuration**: no hooks, no daemon, no
wrapper scripts. Start it and it discovers everything from signals the OS
already exposes.

```
┌──────────────────────────────────┐
│ Claude Sessions                  │
│ ACTIVE                           │
│ 🟢 ai-sidebar               ⏸    │   green pulses while Claude works
│    Build macOS dock widget       │   live task title, read from Terminal
│ 🟢 prism                    ⏸    │
│    Create course · shell running │   ← knows a background task is alive
│ ⚪ blog-fixes               ⏸    │   idle: done, waiting for you
│ PAUSED                           │
│ ⏸ api-refactor  214k tok    ▶   │   click → resume with full history
│    2h ago · Fix the CSV exporter │   (amber token badge = heavy resume)
├──────────────────────────────────┤
│ [Tuck all] [Collapse all]        │
│ [Restore all]                    │
│ ☐ Show Dock window               │
│ Quit ClaudeDeck                  │
└──────────────────────────────────┘
```

## Features

- **Live status that's actually right.** Green pulsing dot while Claude
  works, gray when idle — including the tricky case where Claude's prompt is
  free but a background shell it launched is still running (the session will
  pick itself back up, so it counts as working, with a "shell running" hint).
- **Click to focus.** Any session row brings its Terminal window to the
  front, selects the right tab, and restores a sane size if it was tucked.
- **Tuck / Collapse / Restore.** One click shrinks every Terminal window into
  a tidy bottom-right grid of tiles (Tuck), or a card-deck stack at minimum
  size (Collapse). Restore puts everything back where it was — original
  positions persist across app restarts.
- **Pause & resume sessions.** Pause cleanly ends a session's `claude`
  process (SIGTERM, never SIGKILL) and closes its window — reclaiming a few
  hundred MB of RAM per session — while the conversation stays on disk.
  The Paused list shows each resumable session with its title, age, and
  **context size in tokens** (amber when a full resume would be expensive);
  one click reopens it via `claude --resume` with full history.
- **Menu bar badge** with the number of currently-working sessions
  (SF Symbol `rectangle.stack`), plus an optional regular Dock window.

## How it works

ClaudeDeck polls every 2 seconds, entirely off the main thread, using only
OS-level signals:

- **Discovery.** One `ps -axo pid=,ppid=,%cpu=,tty=,command=` sweep finds
  interactive `claude` processes (real controlling tty, executable basename
  exactly `claude`, helper subcommands and wrappers like
  `caffeinate -is claude …` filtered out). One batched
  `lsof -a -p <pids> -d cwd` call resolves every session's working directory.
- **Status** is a three-tier signal hierarchy, best signal first:
  1. **The terminal title glyph.** Claude Code animates a braille spinner
     (`⠂`, `⠐`, …) in the title while working and shows `✳` when idle. We
     sampled all live sessions every 2 s for 130 s while ground truth was
     known: the glyph split working from idle **100% cleanly across 450+
     samples**. Authoritative, instant, and free — we already read window
     titles.
  2. **Background tool shells.** When Claude's turn ends the glyph goes
     idle — but a task it launched in the background may still be running.
     Every Claude Code tool shell is spawned as
     `zsh -c source ~/.claude/shell-snapshots/snapshot-…`, an unambiguous
     fingerprint no MCP server or helper shares; a session whose process
     parents such a shell counts as working.
  3. **Transcript freshness** (fallback only, e.g. renamed windows): newest
     `.jsonl` under `~/.claude/projects/<encoded-cwd>/` modified within 30 s.
     This is deliberately last — Claude Code writes transcripts in bursts and
     can go minutes without a write mid-task, so mtime alone flaps badly.
- **Windows.** Terminal.app is scriptable: AppleScript (via `osascript` on a
  serial background queue, so the UI never blocks) maps each session's tty to
  a window/tab, reads titles, focuses windows, and sets bounds for
  tuck/collapse/restore.
- **Paused sessions** are discovered from `~/.claude/projects/`: one entry
  per project (its newest transcript) for cwds with no live session. The scan
  stays cheap — directories are re-stat'd each cycle, but a transcript is
  deep-read (head + tail via `FileHandle`, never the whole multi-MB file)
  only when its mtime changes. The true cwd, session id, title, and token
  count all come from inside the transcript, because the encoded directory
  name is lossy.

## Pause & resume, in detail

**Pause** (hover an Active row → ⏸) sends SIGTERM to the session's `claude`
process, waits for it to exit, then closes its Terminal window — silently,
because by then the tab is a bare shell. Nothing is lost: Claude Code streams
its transcript to disk continuously, so pausing only frees the process's
memory and your screen space.

**Resume** (click a Paused row) opens a new Terminal window in the original
working directory running `claude --resume <that exact session>` — the same
transcript file, full conversation history. The row's token badge tells you
before clicking whether you're reopening a light session or an 800k-token
monster (Claude Code will offer a cheaper summary-resume for those).

If Terminal itself isn't running when you resume — say it crashed under
memory pressure — ClaudeDeck clears Terminal's saved window state before
launching it, so macOS doesn't "helpfully" restore every dead window
alongside the one you asked for.

> **Caveat:** pausing interrupts any work in flight — pause gray (idle)
> sessions, not green ones. The conversation survives either way; you may
> just need to re-prompt the interrupted step.

## Engineering notes — bugs we hit so you don't have to

The commit history tells the full story; highlights:

- **`tab` inside a `tell application "Terminal"` block is not the tab
  character** — it resolves to Terminal's *tab class* and stringifies as the
  literal word "tab", silently gluing your field separators together. Bind
  the separator *outside* the tell block.
- **`lsof` lives at `/usr/sbin/lsof`, not `/usr/bin/lsof`.** A hardcoded
  wrong path made every cwd resolution fail — silently, one `guard` at a
  time — so discovery returned zero sessions while everything else worked.
- **Transcript mtime is a lying status signal in both directions**: a
  working session can go 3+ minutes without a write, and an idle one shows a
  fresh write right after its turn ends. The title glyph won on empirical
  data; the CPU heuristic we tried in between (false greens after every
  window resize, because the TUI redraw spikes CPU) was deleted.
- **`repeatForever` SwiftUI animations freeze** when a MenuBarExtra panel
  closes and reopens. The pulsing dot is driven by `TimelineView` instead —
  a clock can't freeze.
- **Unified logging is unreliable for LaunchServices-launched apps** (and
  silently drops everything when the disk fills up — ask us how we know).
  `CLAUDEDECK_DEBUG=1` writes a plain trace file to
  `/tmp/claudedeck-debug.txt` instead.

## Build & run

Requires macOS 13+ and a Swift toolchain (Xcode command line tools).

```bash
swift build                    # compile
bash scripts/make-app.sh       # build a signed app bundle
open build/ClaudeDeck.app
```

## Permissions

On first use, macOS asks to let ClaudeDeck control **Terminal.app**
(Automation). Approve it once. If you decline, the app shows an inline hint
with a button that opens
**System Settings → Privacy & Security → Automation**. That is the only
permission ClaudeDeck needs — no Accessibility, no Full Disk Access.

## Known limitations

- **Terminal.app only** for now. iTerm2 / Ghostty / WezTerm support is the
  most-wanted next step.
- Terminal reports only the **selected tab's** title per window, so with
  multiple Claude tabs in one window, non-selected tabs fall back to the
  weaker transcript signal. One window per session works perfectly.
- Two sessions in the **same working directory**: the Paused list keeps one
  entry per project (the newest transcript); recover older ones with
  `claude --resume`'s built-in picker.

## Debugging

Launch with `CLAUDEDECK_DEBUG=1` to write a trace of discovery, status
decisions, and AppleScript activity to `/tmp/claudedeck-debug.txt`.

## License

[MIT](LICENSE)
