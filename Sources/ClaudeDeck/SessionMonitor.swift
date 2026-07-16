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

    /// The Terminal windows that host the current sessions (for Tuck all).
    func sessionWindows() -> [TermWindow] {
        let ids = Set(sessions.compactMap { $0.terminalWindowID })
        return latestWindows.filter { ids.contains($0.id) }
    }

    /// Kick off one poll cycle. Heavy work runs off the main thread; the Terminal
    /// snapshot and all publishing happen back on the main thread.
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let discovered = SessionMonitor.discoverSessions()
            DispatchQueue.main.async {
                let windows = self.terminal.snapshot()
                self.terminal.pruneSaved(existingIDs: Set(windows.map { $0.id }))
                self.latestWindows = windows

                var merged = discovered.map { session -> Session in
                    var s = session
                    if let w = windows.first(where: { win in
                        win.ttys.contains { $0.hasSuffix(session.tty) }
                    }) {
                        s.terminalWindowID = w.id
                        s.taskTitle = SessionMonitor.taskTitle(from: w.name)
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
                self.sessions = merged
            }
        }
    }

    // MARK: - Discovery (pure, off-main-thread safe)

    static func discoverSessions() -> [Session] {
        guard let out = runProcess("/bin/ps", ["-axo", "pid=,tty=,command="]) else {
            return []
        }
        var byTty: [String: Session] = [:]
        for rawLine in out.split(separator: "\n") {
            guard let (pid, tty, command) = parsePsLine(String(rawLine)) else { continue }

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
            if byTty[tty] != nil { continue }

            guard let cwd = resolveCwd(pid: pid) else { continue }
            let name = (cwd as NSString).lastPathComponent
            let status = statusFor(cwd: cwd)
            byTty[tty] = Session(
                pid: pid,
                tty: tty,
                cwd: cwd,
                name: name.isEmpty ? cwd : name,
                taskTitle: nil,
                status: status,
                terminalWindowID: nil
            )
        }
        return Array(byTty.values)
    }

    /// Parse a `pid tty command` line from `ps -axo pid=,tty=,command=`.
    static func parsePsLine(_ raw: String) -> (Int32, String, String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let firstSpace = line.firstIndex(of: " ") else { return nil }
        let pidStr = String(line[..<firstSpace])
        guard let pid = Int32(pidStr) else { return nil }

        let afterPid = line[line.index(after: firstSpace)...].drop { $0 == " " }
        guard let secondSpace = afterPid.firstIndex(of: " ") else { return nil }
        let tty = String(afterPid[..<secondSpace])

        let command = String(afterPid[afterPid.index(after: secondSpace)...].drop { $0 == " " })
        guard !command.isEmpty else { return nil }
        return (pid, tty, command)
    }

    /// Resolve a process's cwd via `lsof -a -p <pid> -d cwd -Fn`.
    static func resolveCwd(pid: Int32) -> String? {
        guard let out = runProcess("/usr/bin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else {
            return nil
        }
        for line in out.split(separator: "\n") where line.first == "n" {
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : path
        }
        return nil
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

    /// Working if the newest `.jsonl` in the project dir was modified within 5 s.
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
        return Date().timeIntervalSince(mtime) <= 5 ? .working : .idle
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
