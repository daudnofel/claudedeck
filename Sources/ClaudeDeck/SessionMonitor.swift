import Foundation
import Combine

/// Discovers running Claude Code sessions and derives their status.
///
/// Every 2 seconds it:
///   1. enumerates `claude` CLI processes via `ps` (off the main thread),
///   2. resolves each session's cwd via `lsof`,
///   3. stats the newest transcript `.jsonl` to decide working vs. idle,
///   4. (on the main thread) snapshots Terminal windows to attach a window id
///      and live task title, then publishes the merged `[Session]`.
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var showDockWindow: Bool = false

    /// Owned AppleScript bridge. Exposed so views can observe its permission state.
    let terminal = TerminalController()

    /// Latest Terminal window snapshot, used to resolve session windows for tuck.
    private(set) var latestWindows: [TermWindow] = []

    private var timer: Timer?

    /// Consecutive polls each session (by tty) has shown high CPU. One resize
    /// redraw spikes a single poll; real streaming sustains several.
    private var cpuStreak: [String: Int] = [:]

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
            DispatchQueue.main.async {
                self.isRefreshing = false
                dbg("refresh: discovered \(discovered.count) sessions")
                self.latestWindows = windows

                var merged = discovered.map { session -> Session in
                    var s = session
                    if let w = windows.first(where: { win in
                        win.ttys.contains { $0.hasSuffix(session.tty) }
                    }) {
                        s.terminalWindowID = w.id
                        s.taskTitle = SessionMonitor.taskTitle(from: w.name)
                    }
                    // Debounced CPU signal: only sustained load counts as working.
                    self.cpuStreak[s.tty] = s.cpuPercent >= 10 ? (self.cpuStreak[s.tty] ?? 0) + 1 : 0
                    if s.status == .idle, self.cpuStreak[s.tty, default: 0] >= 2 {
                        s.status = .working
                    }
                    return s
                }
                let liveTtys = Set(discovered.map { $0.tty })
                self.cpuStreak = self.cpuStreak.filter { liveTtys.contains($0.key) }
                // Working sessions first, then alphabetical by name.
                merged.sort {
                    let lw = ($0.status == .working)
                    let rw = ($1.status == .working)
                    if lw != rw { return lw }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                dbg("refresh: \(merged.count) sessions, \(merged.filter { $0.terminalWindowID != nil }.count) matched to windows")
                self.sessions = merged
            }
        }
    }

    // MARK: - Discovery (pure, off-main-thread safe)

    static func discoverSessions() -> [Session] {
        guard let out = runProcess("/bin/ps", ["-axo", "pid=,%cpu=,tty=,command="]) else {
            return []
        }
        var candidates: [(pid: Int32, cpu: Double, tty: String)] = []
        var seenTtys = Set<String>()
        for rawLine in out.split(separator: "\n") {
            guard let (pid, cpu, tty, command) = parsePsLine(String(rawLine)) else { continue }

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
            return Session(
                pid: c.pid,
                tty: c.tty,
                cwd: cwd,
                name: name.isEmpty ? cwd : name,
                taskTitle: nil,
                status: statusFor(cwd: cwd),
                terminalWindowID: nil,
                cpuPercent: c.cpu
            )
        }
    }

    /// Parse a `pid %cpu tty command` line from `ps -axo pid=,%cpu=,tty=,command=`.
    static func parsePsLine(_ raw: String) -> (Int32, Double, String, String)? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))

        func nextField() -> String? {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let field = String(rest[..<space])
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
            return field
        }

        guard let pidStr = nextField(), let pid = Int32(pidStr),
              let cpuStr = nextField(), let cpu = Double(cpuStr),
              let tty = nextField(), !rest.isEmpty else { return nil }
        return (pid, cpu, tty, String(rest))
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

    /// Working if the newest transcript `.jsonl` was modified within 15 s.
    /// (Sustained CPU is layered on separately with a debounce in refresh().)
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
        return Date().timeIntervalSince(mtime) <= 15 ? .working : .idle
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
