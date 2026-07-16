import Foundation

/// Discovers resumable ("paused") Claude Code sessions by scanning
/// `~/.claude/projects`. One entry per project directory: its most recent
/// transcript, but only for working directories that have no live session.
///
/// The scan piggybacks on SessionMonitor's 2 s poll and stays cheap: every
/// cycle it only re-stats directories, and it deep-reads a transcript (head +
/// tail via `FileHandle`, never the whole multi-MB file) solely when the file's
/// mtime changed since the last read. Parsed results are cached keyed by
/// path + mtime.
///
/// The project-directory name under `~/.claude/projects` is a LOSSY encoding of
/// the cwd (every non-alphanumeric char becomes `-`), so the true cwd cannot be
/// recovered from it — it is read from the `cwd` field inside the transcript.
final class PausedScanner {
    /// Cap and freshness window for the Paused list.
    private let maxEntries = 8
    private let maxAge: TimeInterval = 14 * 24 * 60 * 60   // 14 days

    /// Bytes read from each end of a transcript. The head carries the first
    /// message line (true cwd + sessionId); the tail carries the latest
    /// ai-title and recent message lines (cwd/sessionId again, as a fallback).
    private let headBytes = 32 * 1024
    private let tailBytes = 32 * 1024

    private struct Parsed {
        let mtime: Date
        let cwd: String?
        let sessionId: String?
        let subtitle: String?
        let contextTokens: Int?
    }

    /// Deep-read cache keyed by transcript path; reused while mtime is unchanged.
    private var cache: [String: Parsed] = [:]

    /// Build the Paused list. `activeCwds` are the working directories of live
    /// sessions (from discovery) — their projects are excluded. Does file IO
    /// and mutates the internal cache; call off the main thread, one at a time.
    func scan(activeCwds: Set<String>) -> [PausedSession] {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        guard let dirs = try? fm.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let now = Date()
        var seenPaths = Set<String>()
        var result: [PausedSession] = []

        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let newest = newestTranscript(in: dir) else { continue }
            let path = newest.path, mtime = newest.mtime

            // Cheap freshness gate before any read.
            guard now.timeIntervalSince(mtime) <= maxAge else { continue }
            seenPaths.insert(path)

            let p = parsed(path: path, mtime: mtime)
            guard let cwd = p.cwd, let sid = p.sessionId else { continue }
            guard !activeCwds.contains(cwd) else { continue }   // has a live session
            guard fm.fileExists(atPath: cwd) else { continue }   // cwd gone from disk

            let name = (cwd as NSString).lastPathComponent
            result.append(PausedSession(
                cwd: cwd,
                sessionId: sid,
                name: name.isEmpty ? cwd : name,
                subtitle: p.subtitle,
                contextTokens: p.contextTokens,
                lastActivity: mtime
            ))
        }

        // Drop cache entries for transcripts we no longer consider.
        cache = cache.filter { seenPaths.contains($0.key) }

        result.sort { $0.lastActivity > $1.lastActivity }
        if result.count > maxEntries { result.removeLast(result.count - maxEntries) }
        return result
    }

    /// Newest `.jsonl` in a project directory, with its modification date.
    private func newestTranscript(in dir: URL) -> (path: String, mtime: Date)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (String, Date)?
        for f in files where f.pathExtension == "jsonl" {
            guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if best == nil || m > best!.1 { best = (f.path, m) }
        }
        return best
    }

    /// Cached parse; deep-reads only when the mtime has changed.
    private func parsed(path: String, mtime: Date) -> Parsed {
        if let hit = cache[path], hit.mtime == mtime { return hit }
        let fresh = deepRead(path: path, mtime: mtime)
        cache[path] = fresh
        return fresh
    }

    /// Read head + tail of the transcript and pull cwd, sessionId and an
    /// optional subtitle (latest `ai-title`). Never reads the whole file.
    private func deepRead(path: String, mtime: Date) -> Parsed {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Parsed(mtime: mtime, cwd: nil, sessionId: nil, subtitle: nil, contextTokens: nil)
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let headData = (try? handle.read(upToCount: headBytes)) ?? Data()
        var tailData = Data()
        if size > UInt64(headBytes) {
            let off = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try? handle.seek(toOffset: off)
            tailData = (try? handle.readToEnd()) ?? Data()
        }

        let headLines = Self.jsonLines(headData)
        let tailLines = Self.jsonLines(tailData)

        // cwd/sessionId: first available scanning head then tail.
        var cwd: String?
        var sid: String?
        for o in headLines + tailLines {
            if cwd == nil, let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
            if sid == nil, let s = o["sessionId"] as? String, !s.isEmpty { sid = s }
            if cwd != nil && sid != nil { break }
        }
        // Fallback: transcripts are named `<sessionId>.jsonl`.
        if sid == nil {
            let stem = (path as NSString).lastPathComponent
            sid = stem.hasSuffix(".jsonl") ? String(stem.dropLast(6)) : stem
        }

        // Subtitle: the most recent ai-title (tail first, then head).
        var subtitle = latestTitle(in: tailLines)
        if subtitle == nil { subtitle = latestTitle(in: headLines) }

        // Context size: the newest assistant usage record in the tail. What a
        // resume must reload is roughly the last turn's full input context.
        let tokens = latestContextTokens(in: tailLines)

        return Parsed(mtime: mtime, cwd: cwd, sessionId: sid, subtitle: subtitle, contextTokens: tokens)
    }

    /// Approximate current context size: input + cache-read + cache-creation
    /// (+ output) tokens of the most recent `message.usage` record.
    private func latestContextTokens(in lines: [[String: Any]]) -> Int? {
        for o in lines.reversed() {
            guard let message = o["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let total = ["input_tokens", "cache_read_input_tokens",
                         "cache_creation_input_tokens", "output_tokens"]
                .compactMap { usage[$0] as? Int }
                .reduce(0, +)
            if total > 0 { return total }
        }
        return nil
    }

    private func latestTitle(in lines: [[String: Any]]) -> String? {
        for o in lines.reversed() where (o["type"] as? String) == "ai-title" {
            if let t = o["aiTitle"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// Parse newline-delimited JSON objects from a byte blob, skipping any
    /// partial or malformed lines (expected at a mid-file tail boundary).
    static func jsonLines(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        var out: [[String: Any]] = []
        for chunk in data.split(separator: 0x0A) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}
