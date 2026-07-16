# ClaudeDeck — design (2026-07-15)

A tiny native macOS menu bar app that shows all running Claude Code sessions,
their live status, and lets you focus one window or tuck all Terminal windows
into a corner stack. Intended to be open-sourced.

## Problem

Running 5–6 Claude Code sessions in Terminal.app buries the desktop in
windows. There is no at-a-glance way to see which session is actively working
vs. done and waiting for review, and no one-click way to clear the desktop or
jump to a specific session.

## Decisions (validated with user)

- Sessions run in **Terminal.app** only (v1).
- Form: **menu bar app** (primary) with an optional **Dock window mode**
  showing the same list.
- "Tuck" action: **shrink windows into a corner stack** — real resize/move,
  windows stay visible as small tiles in the bottom-right corner.
- Status: two states — **green (pulsing) = actively working**,
  **gray = idle / done / waiting for user**.
- Native **Swift / SwiftUI**, zero third-party dependencies, buildable with
  Swift Package Manager from the CLI.

## Architecture

Three components inside one app:

### 1. Session discovery (poll every ~2 s)

- Enumerate processes via `ps -axo pid=,tty=,comm=,command=` (or libproc) and
  keep rows whose command is a `claude` CLI process (match `claude` binary,
  exclude this app itself).
- For each PID, resolve the working directory via `lsof -a -p <pid> -d cwd`
  (or `proc_pidinfo`). The cwd's last path component is the **session name**.
- Record the controlling **tty** (e.g. `ttys003`) — this is the join key to
  Terminal windows.

### 2. Status engine (zero-config)

- Claude Code appends to a transcript `.jsonl` under
  `~/.claude/projects/<encoded-cwd>/` while working. Encoding: cwd path with
  `/`, spaces, `.` and other non-alphanumerics replaced by `-`
  (e.g. `/Users/x/Desktop/ai sidebar` → `-Users-x-Desktop-ai-sidebar`).
- Every 2 s, stat the most recently modified `.jsonl` in the session's
  project dir. `mtime` within the last 5 s → **working (green, pulsing)**;
  otherwise **idle (gray)**.
- No hooks or config required — works out of the box.
- Known limitation: two sessions in the same cwd share one project dir, so
  they show the same status. Documented, acceptable for v1.

### 3. Window controller (AppleScript only — no Accessibility API)

- Terminal.app is fully scriptable: every tab exposes its `tty`, and every
  window has settable `bounds` and `frontmost`/`index`.
- Map session tty → Terminal window id + tab index by walking
  `windows/tabs of application "Terminal"`.
- **Focus session**: restore the window's saved bounds (if tucked), set the
  window's `frontmost`, select its tab, `activate` Terminal.
- **Tuck all**: save each Claude-session window's current bounds in memory
  (keyed by Terminal window id), then set each window's bounds to a small
  tile (~360×230) laid out in a grid stacked from the bottom-right corner of
  the main screen, leaving a margin. Non-session Terminal windows are left
  alone.
- **Restore all**: put every tucked window back to its saved bounds.
- Permissions: only **Automation** (control Terminal.app) — one system
  prompt on first use. No Accessibility permission needed.

## UI

Menu bar item: SF Symbol (`rectangle.stack`) with a small badge count of
working sessions. Dropdown (SwiftUI `MenuBarExtra` window style):

```
┌─────────────────────────────┐
│ Claude Sessions             │
│ 🟢 ai-sidebar               │   green dot pulses while working
│ 🟢 api-refactor             │   row click → focus that window
│ ⚪ blog-fixes               │
│ ⚪ data-pipeline            │
├─────────────────────────────┤
│ [ Tuck all ] [ Restore all ]│
│ ☐ Show Dock window          │
│ Quit                        │
└─────────────────────────────┘
```

- Empty state: "No Claude Code sessions running."
- If Automation permission is denied: inline hint row with a button opening
  System Settings → Privacy & Security → Automation.
- Dock window mode: toggling flips `NSApp.setActivationPolicy(.regular)` and
  opens a regular window hosting the same list view; toggling off returns to
  `.accessory`.

## Error handling

- AppleScript failures (Terminal not running, window closed mid-action):
  catch, refresh session list, no crash.
- Saved bounds for a window that no longer exists: dropped on next refresh.
- ps/lsof failures: treat as zero sessions, retry next poll.

## Project layout

```
ClaudeDeck/
  Package.swift            # SPM executable target, macOS 13+
  Sources/ClaudeDeck/
    ClaudeDeckApp.swift    # @main, MenuBarExtra + dock-mode window
    SessionMonitor.swift   # discovery + status polling (ObservableObject)
    TerminalController.swift # AppleScript bridge: focus / tuck / restore
    Models.swift           # Session struct, status enum
    SessionListView.swift  # shared list UI
  scripts/make-app.sh      # wraps built binary into ClaudeDeck.app bundle
  README.md
```

## Testing / verification

- `swift build` must succeed clean.
- Manual verification with real Claude Code sessions: discovery lists them,
  status flips green while a session works, tuck/restore round-trips bounds,
  row click focuses the right window/tab.
