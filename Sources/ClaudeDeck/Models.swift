import Foundation

/// Opt-in debug tracing to /tmp/claudedeck-debug.txt, enabled by launching
/// with CLAUDEDECK_DEBUG=1 (unified logging proved unreliable for
/// LaunchServices-launched instances, so this writes a plain file).
let debugEnabled = ProcessInfo.processInfo.environment["CLAUDEDECK_DEBUG"] == "1"

func dbg(_ message: String) {
    guard debugEnabled else { return }
    let line = "\(Date()) \(message)\n"
    let path = "/tmp/claudedeck-debug.txt"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Two-state status, derived primarily from the live spinner glyph in the
/// Terminal title (falling back to transcript freshness). See SessionMonitor.
enum SessionStatus: Equatable {
    case working   // Claude Code is actively working -> green, pulsing
    case idle      // idle / awaiting input -> gray
}

/// A single running Claude Code session.
struct Session: Identifiable, Equatable {
    let pid: Int32
    let tty: String          // controlling tty, e.g. "ttys003" (join key to Terminal tabs)
    let cwd: String          // resolved working directory
    let name: String         // display name = last path component of cwd
    var taskTitle: String?   // live task description parsed from the Terminal window name
    var status: SessionStatus
    var terminalWindowID: Int?
    var cpuPercent: Double = 0  // claude process CPU (informational; status now derives from the title glyph)

    var id: Int32 { pid }
}

/// Terminal.app window bounds in Terminal's coordinate space: {left, top, right, bottom},
/// top-left origin, y increasing downward.
struct Bounds: Equatable {
    var x1: Int
    var y1: Int
    var x2: Int
    var y2: Int
}

/// Snapshot of one Terminal.app window.
struct TermWindow: Identifiable, Equatable {
    let id: Int
    let name: String
    let bounds: Bounds
    let ttys: [String]       // tty of each tab, e.g. ["/dev/ttys003"]
}
