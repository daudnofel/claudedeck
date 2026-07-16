import Foundation
import AppKit
import Combine

/// AppleScript bridge to Terminal.app. All methods run on the main thread
/// (NSAppleScript is not thread-safe). Failures are caught and never crash;
/// an Automation-permission denial (-1743) flips `permissionDenied`.
final class TerminalController: ObservableObject {
    @Published var permissionDenied: Bool = false

    /// Original bounds of tucked windows, keyed by Terminal window id.
    private var savedBounds: [Int: Bounds] = [:]

    // Tile geometry for tuck.
    private let tileW = 360
    private let tileH = 230
    private let gap = 12
    private let margin = 16

    private var terminalRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
    }

    // MARK: - Snapshot

    /// List Terminal windows with id, name, bounds and per-tab ttys.
    /// Returns [] (without launching Terminal) when Terminal is not running.
    func snapshot() -> [TermWindow] {
        guard terminalRunning else { dbg("snapshot: Terminal not running"); return [] }
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
        guard let desc = run(script) else { dbg("snapshot: script returned nil"); return [] }
        let windows = parseSnapshot(desc)
        dbg("snapshot: \(windows.count) windows parsed")
        return windows
    }

    private func parseSnapshot(_ desc: NSAppleEventDescriptor) -> [TermWindow] {
        guard let text = desc.stringValue else { return [] }
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
            windows.append(TermWindow(id: id, name: name, bounds: bounds, ttys: ttys))
        }
        return windows
    }

    // MARK: - Focus

    /// Bring a session's window and tab to the front, restoring its bounds if tucked.
    func focusSession(windowID: Int, tty: String) {
        guard terminalRunning else { return }
        var boundsLine = ""
        if let b = savedBounds[windowID] {
            boundsLine = "    set bounds of targetWin to {\(b.x1), \(b.y1), \(b.x2), \(b.y2)}"
            savedBounds[windowID] = nil
        }
        let devtty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "Terminal"
          try
            set targetWin to (first window whose id is \(windowID))
        \(boundsLine)
            set frontmost of targetWin to true
            try
              set selected tab of targetWin to (first tab of targetWin whose tty is "\(devtty)")
            end try
          end try
          activate
        end tell
        """
        run(script)
    }

    // MARK: - Tuck / Restore

    /// Save each window's current bounds (once) and tile them into the
    /// bottom-right corner of the main screen.
    func tuckAll(windows: [TermWindow]) {
        dbg("tuckAll: called with \(windows.count) windows, terminalRunning=\(terminalRunning)")
        guard terminalRunning, !windows.isEmpty else { return }
        for w in windows where savedBounds[w.id] == nil {
            savedBounds[w.id] = w.bounds
        }
        let tiles = computeTiles(count: windows.count)
        var body = ""
        for (i, w) in windows.enumerated() {
            let t = tiles[i]
            body += """
              try
                set bounds of (first window whose id is \(w.id)) to {\(t.x1), \(t.y1), \(t.x2), \(t.y2)}
              end try

            """
        }
        run("tell application \"Terminal\"\n\(body)end tell")
    }

    /// Restore every tucked window to its saved bounds, then forget them.
    func restoreAll() {
        guard terminalRunning, !savedBounds.isEmpty else { return }
        var body = ""
        for (id, b) in savedBounds {
            body += """
              try
                set bounds of (first window whose id is \(id)) to {\(b.x1), \(b.y1), \(b.x2), \(b.y2)}
              end try

            """
        }
        run("tell application \"Terminal\"\n\(body)end tell")
        savedBounds.removeAll()
    }

    /// Drop saved bounds for windows that no longer exist.
    func pruneSaved(existingIDs: Set<Int>) {
        savedBounds = savedBounds.filter { existingIDs.contains($0.key) }
    }

    // MARK: - Tile layout

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

    // MARK: - AppleScript execution

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let num = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            dbg("AppleScript error \(num): \(msg)")
            // -1743: user has not authorized Automation. -1744: needs UI consent.
            if num == -1743 || num == -1744 {
                permissionDenied = true
            }
            return nil
        }
        if permissionDenied { permissionDenied = false }
        return result
    }
}
