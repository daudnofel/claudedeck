import Foundation
import Combine

/// Discovers running Claude Code sessions and derives their status.
///
/// Every 2 seconds it:
///   1. enumerates `claude` CLI processes via `ps` (off the main thread),
///   2. resolves each session's cwd via `lsof`,
///   3. (on the main thread) snapshots Terminal windows to attach a window id
///      and live task title, then publishes the merged `[Session]`.
///
/// Status (working vs. idle) is decided by a two-tier signal hierarchy, best
/// signal first:
///   1. the live status glyph in the matched window's title — Claude Code
///      animates a braille spinner while working and shows ✳ while idle
///      (`statusFromTitle`). Authoritative, instant and free.
///   2. fallback, only when no glyph is available (window unmatched, renamed,
///      or task not set yet): transcript `.jsonl` freshness (`statusFor`).
///      Weak — Claude Code writes the transcript in bursts and can go minutes
///      without a write mid-task — so it is strictly a last resort.
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pausedSessions: [PausedSession] = []
    @Published var showDockWindow: Bool = false

    /// Owned AppleScript bridge. Exposed so views can observe its permission state.
    let terminal = TerminalController()

    /// Scans `~/.claude/projects` for resumable sessions. Confined to the poll's
    /// background block (serialized by `isRefreshing`).
    private let pausedScanner = PausedScanner()

    /// Latest Terminal window snapshot, used to resolve session windows for tuck.
    private(set) var latestWindows: [TermWindow] = []

    private var timer: Timer?

    init() {
        // Add in .common mode so polling keeps running while the menu popover is open.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    /// Skip a poll if the previous one is still in flight (main-thread flag).
    private var isRefreshing = false

    /// Kick off one poll cycle. Discovery AND the Terminal snapshot run off
    /// the main thread; only merging and publishing happen on the main thread.
    func refresh() {
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let discovered = SessionMonitor.discoverSessions()
            let windows = self.terminal.snapshotSync()
            // Paused = resumable transcripts whose cwd has no live session.
            let activeCwds = Set(discovered.map { $0.cwd })
            let paused = self.pausedScanner.scan(activeCwds: activeCwds)
            DispatchQueue.main.async {
                self.isRefreshing = false
                dbg("refresh: discovered \(discovered.count) sessions, \(paused.count) paused")
                self.latestWindows = windows
                self.pausedSessions = paused

                var merged = discovered.map { session -> Session in
                    var s = session
                    if let w = windows.first(where: { win in
                        win.ttys.contains { $0.hasSuffix(session.tty) }
                    }) {
                        s.terminalWindowID = w.id
                        s.taskTitle = SessionMonitor.taskTitle(from: w.name)
                        // Primary, authoritative signal: the live status glyph in
                        // the window title (braille spinner = working, ✳ = idle).
                        // Instant and free — we already have the title. It overrides
                        // the mtime fallback already set in s.status. Only when the
                        // glyph is absent or unrecognized do we keep that fallback.
                        if let glyphStatus = SessionMonitor.statusFromTitle(w.name) {
                            s.status = glyphStatus
                        }
                    }
                    // The glyph goes idle the moment the prompt frees up, but a
                    // background task Claude launched may still be running — and
                    // the session will pick itself back up when it finishes.
                    // A live Bash-tool shell child means work is still happening.
                    if s.status == .idle, s.hasRunningShell {
                        s.status = .working
                    }
                    return s
                }
                // Working sessions first, then alphabetical by name.
                merged.sort {
                    let lw = ($0.status == .working)
                    let rw = ($1.status == .working)
                    if lw != rw { return lw }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                dbg("refresh: \(merged.count) sessions, \(merged.filter { $0.terminalWindowID != nil }.count) matched to windows")
                for p in paused { dbg("  paused: \(p.name) [\(p.sessionId)] \(p.cwd)") }
                self.sessions = merged
            }
        }
    }

    // MARK: - Pause / Resume

    /// Pause a live session: end its `claude` process cleanly (SIGTERM, never
    /// SIGKILL — the transcript is already on disk), wait for it to exit, then
    /// close its Terminal window. The session moves from Active to Paused;
    /// resume reopens it with full history. Any work in flight is interrupted,
    /// not lost — the conversation is preserved.
    func pauseSession(_ session: Session) {
        let pid = session.pid
        let windowID = session.terminalWindowID
        dbg("pause: \(session.name) pid=\(pid) window=\(windowID.map(String.init) ?? "-")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let gone = SessionMonitor.terminateAndWait(pid: pid, timeout: 3.0)
            dbg("pause: pid \(pid) exited=\(gone)")
            // Only close once the process is gone: closing a window with a live
            // claude would raise Terminal's "processes are running" prompt. A
            // brief settle lets the shell return to a bare prompt (and claude's
            // caffeinate child reap) so the close is silent.
            if gone, let wid = windowID {
                usleep(500_000)
                self.terminal.closeWindow(id: wid)
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Resume a paused session in a NEW Terminal window, full history intact.
    func resume(_ paused: PausedSession) {
        dbg("resume: \(paused.name) session=\(paused.sessionId)")
        terminal.resumeSession(cwd: paused.cwd, sessionId: paused.sessionId)
        // Give the new window a moment to appear, then re-poll so it lands in
        // Active (and drops out of Paused).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    /// SIGTERM a pid and poll (up to `timeout`) until it is gone. Returns true
    /// once the process has exited. Never sends SIGKILL — Claude Code flushes
    /// and exits cleanly on SIGTERM, and the transcript is already on disk.
    static func terminateAndWait(pid: Int32, timeout: TimeInterval) -> Bool {
        if kill(pid, SIGTERM) != 0 {
            return errno == ESRCH   // already gone counts as success
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(100_000)   // 100 ms
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    // MARK: - Discovery (pure, off-main-thread safe)

    static func discoverSessions() -> [Session] {
        guard let out = runProcess("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,tty=,command="]) else {
            return []
        }
        var candidates: [(pid: Int32, cpu: Double, tty: String)] = []
        var seenTtys = Set<String>()
        // Parents of live Bash-tool shells: Claude Code runs every tool shell
        // (foreground or background task) as `/bin/zsh -c source
        // ~/.claude/shell-snapshots/snapshot-…`, a fingerprint no MCP server or
        // helper shares. Used to catch "idle prompt but background task alive".
        var shellParents = Set<Int32>()
        for rawLine in out.split(separator: "\n") {
            guard let (pid, ppid, cpu, tty, command) = parsePsLine(String(rawLine)) else { continue }
            if command.contains("/.claude/shell-snapshots/") { shellParents.insert(ppid) }

            // Rule 1: a real interactive session has a controlling tty.
            if tty == "??" { continue }

            let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let exe = parts.first else { continue }

            // Rule 2: the executable's basename must be exactly `claude`
            // (excludes wrappers like `caffeinate -is claude ...`).
            let base = (exe as NSString).lastPathComponent
            guard base == "claude" else { continue }

            // Rule 3: exclude helper subcommands.
            let firstArg = parts.count > 1 ? parts[1] : ""
            if firstArg == "bg-pty-host" || firstArg == "bg-spare" || firstArg == "daemon" {
                continue
            }

            // Rule 4: one session per tty.
            guard seenTtys.insert(tty).inserted else { continue }
            candidates.append((pid, cpu, tty))
        }

        // One batched lsof call for all pids instead of one subprocess each.
        let cwds = resolveCwds(pids: candidates.map { $0.pid })
        return candidates.compactMap { c in
            guard let cwd = cwds[c.pid] else { return nil }
            let name = (cwd as NSString).lastPathComponent
            var session = Session(
                pid: c.pid,
                tty: c.tty,
                cwd: cwd,
                name: name.isEmpty ? cwd : name,
                taskTitle: nil,
                status: statusFor(cwd: cwd),
                terminalWindowID: nil,
                cpuPercent: c.cpu
            )
            session.hasRunningShell = shellParents.contains(c.pid)
            return session
        }
    }

    /// Parse a `pid ppid %cpu tty command` line from
    /// `ps -axo pid=,ppid=,%cpu=,tty=,command=`.
    static func parsePsLine(_ raw: String) -> (Int32, Int32, Double, String, String)? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))

        func nextField() -> String? {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let field = String(rest[..<space])
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
            return field
        }

        guard let pidStr = nextField(), let pid = Int32(pidStr),
              let ppidStr = nextField(), let ppid = Int32(ppidStr),
              let cpuStr = nextField(), let cpu = Double(cpuStr),
              let tty = nextField(), !rest.isEmpty else { return nil }
        return (pid, ppid, cpu, tty, String(rest))
    }

    /// Resolve cwds for many pids in ONE `lsof` call.
    /// `-Fpn` output interleaves `p<pid>` and `n<path>` lines.
    static func resolveCwds(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = runProcess("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fpn"]) else {
            return [:]
        }
        var result: [Int32: String] = [:]
        var currentPid: Int32?
        for line in out.split(separator: "\n") {
            if line.first == "p" {
                currentPid = Int32(line.dropFirst())
            } else if line.first == "n", let pid = currentPid {
                let path = String(line.dropFirst())
                if !path.isEmpty { result[pid] = path }
            }
        }
        return result
    }

    /// Encode a cwd into its `~/.claude/projects/<encoded>` directory name:
    /// every character that is not [A-Za-z0-9] becomes `-` (leading `/` included).
    static func encodeProjectDir(_ cwd: String) -> String {
        var result = ""
        result.reserveCapacity(cwd.count)
        for scalar in cwd.unicodeScalars {
            let v = scalar.value
            let isAlnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            result.append(isAlnum ? Character(scalar) : "-")
        }
        return result
    }

    /// FALLBACK status, used only when the matched window title carries no
    /// recognizable status glyph (window unmatched, renamed, or task not set
    /// yet). Working if the newest transcript `.jsonl` was modified within 30 s.
    ///
    /// This is a deliberately weak signal: Claude Code writes the transcript in
    /// bursts, so a genuinely working session can go far longer than 30 s between
    /// writes (and a just-finished, idle session can look fresh for a moment).
    /// The title glyph (`statusFromTitle`) is always preferred when available.
    static func statusFor(cwd: String) -> SessionStatus {
        let encoded = encodeProjectDir(cwd)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .idle
        }

        var latest: Date?
        for f in files where f.pathExtension == "jsonl" {
            if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
               let m = vals.contentModificationDate {
                if latest == nil || m > latest! { latest = m }
            }
        }
        guard let mtime = latest else { return .idle }
        return Date().timeIntervalSince(mtime) <= 30 ? .working : .idle
    }

    /// PRIMARY status signal: parse the live status glyph Claude Code animates
    /// into the Terminal window title, immediately before the task text —
    /// "cwd — <glyph> task — 120×30".
    ///
    /// Calibrated from an empirical trace of 7 live sessions: an actively
    /// working session shows a braille spinner (U+2800–U+28FF, e.g. ⠂ ⠐) while
    /// an idle session awaiting input shows ✳ (U+2733). The split was clean —
    /// 121 braille samples on the two working sessions, 324 ✳ samples on the
    /// five idle ones, no overlap. Other documented spinner frames (·✢✶✻✽) are
    /// treated as working too for robustness across Claude Code versions.
    ///
    /// Returns nil when the leading glyph is missing or unrecognized (plain
    /// shell, renamed window, no task yet) so the caller can fall back to mtime.
    ///
    /// Caveat: Terminal's window `name` reflects only the SELECTED tab, so in a
    /// multi-tab window the glyph belongs to whichever tab is frontmost. This
    /// user's windows are single-tab, so it is always the right session.
    static func statusFromTitle(_ windowName: String) -> SessionStatus? {
        let segments = windowName.components(separatedBy: "\u{2014}") // em dash
        guard segments.count >= 2,
              let glyph = segments[1].unicodeScalars.first(where: {
                  !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }
        switch glyph.value {
        case 0x2800...0x28FF:                        return .working // braille spinner
        case 0x00B7, 0x2722, 0x2736, 0x273B, 0x273D: return .working // other spinner frames
        case 0x2733:                                 return .idle    // ✳ awaiting input
        default:                                     return nil      // unknown → fall back
        }
    }

    /// Pull the live task description out of a Terminal window name such as
    /// "ai sidebar — ⠂ Build macOS dock widget — 120×30". The middle segment
    /// (between em-dash separators) is the task, with leading status glyphs and
    /// whitespace stripped.
    static func taskTitle(from windowName: String) -> String? {
        let segments = windowName.components(separatedBy: "\u{2014}") // em dash
        guard segments.count >= 2 else { return nil }
        var mid = segments[1]
        while let f = mid.unicodeScalars.first, !CharacterSet.alphanumerics.contains(f) {
            mid.unicodeScalars.removeFirst()
        }
        let cleaned = mid.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Run a command and capture stdout as UTF-8. Returns nil on launch failure.
    static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
