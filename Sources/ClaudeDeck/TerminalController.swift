import Foundation
import AppKit
import Combine

/// AppleScript bridge to Terminal.app.
///
/// All scripts execute via `osascript` on a private serial queue so the UI
/// thread never blocks; geometry is computed on the caller's (main) thread
/// since it touches NSScreen. `savedBounds` is confined to the script queue.
final class TerminalController: ObservableObject {
    @Published var permissionDenied: Bool = false

    private let scriptQueue = DispatchQueue(label: "com.claudedeck.applescript", qos: .userInitiated)

    /// Original bounds of tucked windows, keyed by Terminal window id.
    /// Persisted to UserDefaults so an app restart never forgets where
    /// tucked windows came from. Confined to `scriptQueue` after init.
    private var savedBounds: [Int: Bounds] = [:] {
        didSet { persistSavedBounds() }
    }

    private static let savedBoundsKey = "savedWindowBounds"

    // Tile geometry for tuck.
    private let tileW = 360
    private let tileH = 230
    private let gap = 12
    private let margin = 16

    init() {
        savedBounds = Self.loadSavedBounds()
    }

    private func persistSavedBounds() {
        let encoded = savedBounds.reduce(into: [String: [Int]]()) {
            $0["\($1.key)"] = [$1.value.x1, $1.value.y1, $1.value.x2, $1.value.y2]
        }
        UserDefaults.standard.set(encoded, forKey: Self.savedBoundsKey)
    }

    private static func loadSavedBounds() -> [Int: Bounds] {
        guard let raw = UserDefaults.standard.dictionary(forKey: savedBoundsKey) as? [String: [Int]] else {
            return [:]
        }
        return raw.reduce(into: [Int: Bounds]()) {
            guard let id = Int($1.key), $1.value.count == 4 else { return }
            $0[id] = Bounds(x1: $1.value[0], y1: $1.value[1], x2: $1.value[2], y2: $1.value[3])
        }
    }

    private var terminalRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
    }

    // MARK: - Snapshot

    /// List Terminal windows with id, name, bounds and per-tab ttys.
    /// Blocking; call from a background thread (SessionMonitor's poll path).
    /// Returns [] (without launching Terminal) when Terminal is not running.
    func snapshotSync() -> [TermWindow] {
        guard terminalRunning else { return [] }
        // `sep` must be bound OUTSIDE the tell block: inside it, `tab` resolves
        // to Terminal's tab class (stringifying as "tab"), not the tab character.
        let script = """
        set sep to tab
        tell application "Terminal"
          set out to ""
          repeat with w in windows
            set wid to id of w
            set wname to name of w
            set b to bounds of w
            set ttys to ""
            repeat with t in tabs of w
              set ttys to ttys & (tty of t) & ","
            end repeat
            set out to out & wid & sep & wname & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & sep & ttys & linefeed
          end repeat
          return out
        end tell
        """
        return scriptQueue.sync {
            guard let text = runScript(script) else { dbg("snapshot: script failed"); return [] }
            let windows = Self.parseSnapshot(text)
            // Prune saved bounds for windows that no longer exist.
            let ids = Set(windows.map { $0.id })
            savedBounds = savedBounds.filter { ids.contains($0.key) }
            return windows
        }
    }

    static func parseSnapshot(_ text: String) -> [TermWindow] {
        var windows: [TermWindow] = []
        for rawLine in text.split(separator: "\n") {
            let fields = String(rawLine).components(separatedBy: "\t")
            guard fields.count >= 4 else { continue }
            guard let id = Int(fields[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = fields[1]
            let nums = fields[2].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard nums.count == 4 else { continue }
            let bounds = Bounds(x1: nums[0], y1: nums[1], x2: nums[2], y2: nums[3])
            let ttys = fields[3]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Skip tab-less husks: closing a window via AppleScript can leave an
            // invisible, zero-tab window object behind (see closeWindow). Those
            // carry no tty, so they never match a session and must not consume a
            // tuck grid slot.
            guard !ttys.isEmpty else { continue }
            windows.append(TermWindow(id: id, name: name, bounds: bounds, ttys: ttys))
        }
        return windows
    }

    // MARK: - Focus

    /// Bring a session's window and tab to the front, restoring its bounds if
    /// tucked. Degenerate "originals" (tile-sized, e.g. saved after an app
    /// restart mid-tuck) are replaced by a comfortable default size.
    /// Non-blocking; safe to call from the UI.
    func focusSession(windowID: Int, tty: String, currentBounds: Bounds? = nil) {
        guard terminalRunning else { return }
        let fallback = defaultRestoreBounds()   // NSScreen: main thread
        let minUsableW = tileW + 140
        let minUsableH = tileH + 120
        let devtty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        scriptQueue.async { [weak self] in
            guard let self else { return }
            var target = self.savedBounds[windowID]
            self.savedBounds[windowID] = nil
            if let t = target, (t.x2 - t.x1) < minUsableW || (t.y2 - t.y1) < minUsableH {
                target = fallback
            }
            // No saved original but the window is currently tile-sized: expand it.
            if target == nil, let c = currentBounds,
               (c.x2 - c.x1) < minUsableW, (c.y2 - c.y1) < minUsableH {
                target = fallback
            }
            var boundsLine = ""
            if let b = target {
                boundsLine = "    set bounds of targetWin to {\(b.x1), \(b.y1), \(b.x2), \(b.y2)}"
            }
            dbg("focusSession: window \(windowID), restore=\(target.map { "\($0)" } ?? "none")")
            let script = """
            tell application "Terminal"
              try
                set targetWin to window id \(windowID)
            \(boundsLine)
                set frontmost of targetWin to true
                try
                  set selected tab of targetWin to (first tab of targetWin whose tty is "\(devtty)")
                end try
              end try
              activate
            end tell
            """
            self.runScript(script)
        }
    }

    // MARK: - Pause / Resume

    /// Close a Terminal window by id after its session's `claude` process has
    /// exited (the tab is a bare shell, so Terminal closes it without a prompt).
    /// `saving no` suppresses the save prompt. Non-blocking; forgets any tuck
    /// bounds for the window.
    ///
    /// Note: Terminal frequently keeps an invisible, zero-tab window object
    /// behind after such a close. It is harmless — not shown on screen and
    /// carrying no tty — and `parseSnapshot` filters it out.
    func closeWindow(id: Int) {
        guard terminalRunning else { return }
        scriptQueue.async { [weak self] in
            guard let self else { return }
            dbg("closeWindow: \(id)")
            self.savedBounds[id] = nil
            self.runScript("""
            tell application "Terminal"
              try
                close (every window whose id is \(id)) saving no
              end try
            end tell
            """)
        }
    }

    /// Open a NEW Terminal window running `claude --resume <sessionId>` in `cwd`,
    /// then bring Terminal to the front. The cwd is shell-quoted (paths contain
    /// spaces and quotes). Non-blocking. `do script` launches Terminal if it is
    /// not already running.
    func resumeSession(cwd: String, sessionId: String) {
        let command = "cd \(Self.shellSingleQuote(cwd)) && claude --resume \(sessionId)"
        scriptQueue.async { [weak self] in
            guard let self else { return }
            // Cold start: `do script` is about to LAUNCH Terminal, and if
            // Terminal previously crashed, macOS state restoration would
            // reopen every old window alongside ours — after an
            // out-of-memory crash that's the worst possible moment for it.
            // Clearing the saved state first makes a cold resume open
            // exactly the one window asked for. (Never touched while
            // Terminal is running — quit/relaunch behaves as the user set.)
            if !self.terminalRunning {
                let saved = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Saved Application State/com.apple.Terminal.savedState")
                try? FileManager.default.removeItem(at: saved)
                dbg("resumeSession: cold start, cleared Terminal saved state")
            }
            dbg("resumeSession: \(command)")
            self.runScript("""
            tell application "Terminal"
              do script \(Self.appleScriptLiteral(command))
              activate
            end tell
            """)
        }
    }

    /// Wrap a string in single quotes for the shell, escaping embedded quotes.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Encode a string as an AppleScript string literal (escaping `\` and `"`).
    static func appleScriptLiteral(_ s: String) -> String {
        var e = s.replacingOccurrences(of: "\\", with: "\\\\")
        e = e.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + e + "\""
    }

    // MARK: - Tuck / Collapse / Restore

    /// Shrink every window into a bottom-right grid of small tiles.
    func tuckAll(windows: [TermWindow]) {
        dbg("tuckAll: called with \(windows.count) windows")
        applyLayout(windows: windows, frames: computeTiles(count: windows.count))
    }

    /// Collapse every window into a card-deck stack of minimum-size windows
    /// in the bottom-right corner (Terminal clamps to its own minimum size).
    func collapseAll(windows: [TermWindow]) {
        dbg("collapseAll: called with \(windows.count) windows")
        applyLayout(windows: windows, frames: computeStack(count: windows.count))
    }

    /// Save originals (once) and move each window to its target frame.
    /// Non-blocking; safe to call from the UI.
    private func applyLayout(windows: [TermWindow], frames: [Bounds]) {
        guard terminalRunning, !windows.isEmpty else { return }
        scriptQueue.async { [weak self] in
            guard let self else { return }
            for w in windows where self.savedBounds[w.id] == nil {
                // Never record a tile-sized frame as an "original" (e.g. a window
                // still tucked by a previous run) — restore would go nowhere useful.
                if (w.bounds.x2 - w.bounds.x1) <= self.tileW + 40,
                   (w.bounds.y2 - w.bounds.y1) <= self.tileH + 40 {
                    continue
                }
                self.savedBounds[w.id] = w.bounds
            }
            var body = ""
            for (i, w) in windows.enumerated() {
                let t = frames[i]
                body += """
                  try
                    set bounds of window id \(w.id) to {\(t.x1), \(t.y1), \(t.x2), \(t.y2)}
                  end try

                """
            }
            self.runScript("tell application \"Terminal\"\n\(body)end tell")
        }
    }

    /// Restore every tucked window to its saved bounds, then forget them.
    /// Tile-sized windows with no saved original (e.g. tucked before an app
    /// restart) are expanded to the default size, slightly cascaded.
    /// Non-blocking; safe to call from the UI.
    func restoreAll(windows: [TermWindow]) {
        guard terminalRunning else { return }
        let fallback = defaultRestoreBounds()   // NSScreen: main thread
        scriptQueue.async { [weak self] in
            guard let self else { return }
            var targets: [(id: Int, b: Bounds)] = []
            var cascade = 0
            for w in windows {
                if let b = self.savedBounds[w.id] {
                    targets.append((w.id, b))
                } else if (w.bounds.x2 - w.bounds.x1) <= self.tileW + 40,
                          (w.bounds.y2 - w.bounds.y1) <= self.tileH + 40 {
                    let b = Bounds(x1: fallback.x1 + cascade, y1: fallback.y1 + cascade,
                                   x2: fallback.x2 + cascade, y2: fallback.y2 + cascade)
                    cascade += 28
                    targets.append((w.id, b))
                }
            }
            dbg("restoreAll: \(targets.count) windows (\(self.savedBounds.count) saved)")
            guard !targets.isEmpty else { return }
            var body = ""
            for t in targets {
                body += """
                  try
                    set bounds of window id \(t.id) to {\(t.b.x1), \(t.b.y1), \(t.b.x2), \(t.b.y2)}
                  end try

                """
            }
            self.runScript("tell application \"Terminal\"\n\(body)end tell")
            self.savedBounds.removeAll()
        }
    }

    // MARK: - Geometry (main thread: touches NSScreen)

    /// A comfortable centered window size (~60% of the visible screen) used
    /// when a window has no usable original bounds to restore to.
    private func defaultRestoreBounds() -> Bounds {
        guard let screen = NSScreen.main else {
            return Bounds(x1: 200, y1: 120, x2: 1300, y2: 880)
        }
        let fullH = Int(screen.frame.height.rounded())
        let vf = screen.visibleFrame
        let left = Int(vf.origin.x.rounded())
        let width = Int(vf.size.width.rounded())
        let top = fullH - Int((vf.origin.y + vf.size.height).rounded())
        let height = Int(vf.size.height.rounded())

        let w = min(1200, width * 6 / 10)
        let h = min(800, height * 7 / 10)
        let x1 = left + (width - w) / 2
        let y1 = top + (height - h) / 2
        return Bounds(x1: x1, y1: y1, x2: x1 + w, y2: y1 + h)
    }

    /// Card-deck stack: minimum-size windows piled in the bottom-right corner,
    /// each offset a little up-left so the stack reads like rectangle.stack.
    private func computeStack(count: Int) -> [Bounds] {
        guard count > 0 else { return [] }
        let cardW = 220, cardH = 140, step = 14
        var right = 1400, bottom = 850
        if let screen = NSScreen.main {
            let fullH = Int(screen.frame.height.rounded())
            let vf = screen.visibleFrame
            right = Int((vf.origin.x + vf.size.width).rounded()) - margin
            bottom = fullH - Int(vf.origin.y.rounded()) - margin
        }
        return (0..<count).map { i in
            let x2 = right - i * step
            let y2 = bottom - i * step
            return Bounds(x1: x2 - cardW, y1: y2 - cardH, x2: x2, y2: y2)
        }
    }

    private func computeTiles(count: Int) -> [Bounds] {
        guard count > 0 else { return [] }
        guard let screen = NSScreen.main else {
            return (0..<count).map { i in
                Bounds(x1: 100 + i * 20, y1: 100 + i * 20,
                       x2: 100 + i * 20 + tileW, y2: 100 + i * 20 + tileH)
            }
        }
        // Convert the Cocoa (bottom-left origin) visible frame into Terminal's
        // top-left origin coordinate space.
        let fullH = Int(screen.frame.height.rounded())
        let vf = screen.visibleFrame
        let usableLeft = Int(vf.origin.x.rounded())
        let usableRight = Int((vf.origin.x + vf.size.width).rounded())
        let usableBottom = fullH - Int(vf.origin.y.rounded())
        let usableWidth = usableRight - usableLeft

        var cols = (usableWidth - 2 * margin + gap) / (tileW + gap)
        if cols < 1 { cols = 1 }

        var tiles: [Bounds] = []
        tiles.reserveCapacity(count)
        for i in 0..<count {
            let col = i % cols
            let row = i / cols
            let x2 = usableRight - margin - col * (tileW + gap)
            let x1 = x2 - tileW
            let y2 = usableBottom - margin - row * (tileH + gap)
            let y1 = y2 - tileH
            tiles.append(Bounds(x1: x1, y1: y1, x2: x2, y2: y2))
        }
        return tiles
    }

    // MARK: - Script execution (scriptQueue only)

    /// Run a script via osascript, returning stdout on success or nil on error.
    /// Must be called on `scriptQueue`.
    @discardableResult
    private func runScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            dbg("osascript launch failed: \(error)")
            return nil
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            dbg("AppleScript error: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            // -1743: user has not authorized Automation. -1744: needs UI consent.
            let denied = err.contains("-1743") || err.contains("-1744")
            DispatchQueue.main.async { self.permissionDenied = denied }
            return nil
        }
        DispatchQueue.main.async {
            if self.permissionDenied { self.permissionDenied = false }
        }
        return String(data: outData, encoding: .utf8)
    }
}
