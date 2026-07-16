import Foundation

/// Two-state status derived from the session's transcript activity.
enum SessionStatus: Equatable {
    case working   // transcript touched within the last few seconds -> green, pulsing
    case idle      // otherwise -> gray
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
