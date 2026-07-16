import SwiftUI
import AppKit

/// Shared list UI used by both the menu bar popover and the Dock window.
struct SessionListView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var terminal: TerminalController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var header: some View {
        Text("Claude Sessions")
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if terminal.permissionDenied {
            permissionHint
        }
        activeSection
        pausedSection
    }

    @ViewBuilder
    private var activeSection: some View {
        if monitor.sessions.isEmpty {
            Text("No Claude Code sessions running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            sectionHeader("Active")
            VStack(spacing: 0) {
                ForEach(monitor.sessions) { session in
                    SessionRow(
                        session: session,
                        onTap: { focus(session) },
                        onPause: { monitor.pauseSession(session) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var pausedSection: some View {
        if !monitor.pausedSessions.isEmpty {
            sectionHeader("Paused")
            VStack(spacing: 0) {
                ForEach(monitor.pausedSessions) { paused in
                    PausedRow(paused: paused) { monitor.resume(paused) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// Focus a session's window and tab, restoring its bounds if tucked.
    private func focus(_ session: Session) {
        guard let wid = session.terminalWindowID else { return }
        let current = monitor.latestWindows.first { $0.id == wid }?.bounds
        terminal.focusSession(windowID: wid, tty: session.tty, currentBounds: current)
    }

    private var permissionHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow ClaudeDeck to control Terminal to focus and tuck windows.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Tuck all") {
                    terminal.tuckAll(windows: monitor.latestWindows)
                }
                Button("Collapse all") {
                    terminal.collapseAll(windows: monitor.latestWindows)
                }
                Button("Restore all") {
                    terminal.restoreAll(windows: monitor.latestWindows)
                }
            }
            Toggle("Show Dock window", isOn: dockBinding)
                .toggleStyle(.checkbox)
            Divider()
            Button("Quit ClaudeDeck") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Toggling flips the activation policy and opens/closes the Dock window.
    private var dockBinding: Binding<Bool> {
        Binding(
            get: { monitor.showDockWindow },
            set: { newValue in
                monitor.showDockWindow = newValue
                if newValue {
                    DockWindow.shared.show(monitor: monitor, terminal: terminal) {
                        monitor.showDockWindow = false
                    }
                } else {
                    DockWindow.shared.hide()
                }
            }
        )
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: Session
    let onTap: () -> Void
    let onPause: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let task = session.taskTitle, !task.isEmpty {
                        Text(task)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Pause affordance, revealed on hover. Rendered as an overlay sibling
        // (not nested in the row Button) so its clicks don't also focus.
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: onPause) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pause session (close window, resume anytime)")
                .padding(.trailing, 12)
            }
        }
    }
}

// MARK: - Paused row

private struct PausedRow: View {
    let paused: PausedSession
    let onResume: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(paused.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let tokens = paused.contextTokens {
                            // Amber above ~150k tokens: resuming as-is is expensive
                            // and Claude Code will suggest resuming from a summary.
                            Text(formatTokens(tokens))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tokens > 150_000 ? Color.orange : Color.secondary)
                        }
                    }
                    Text(subtitleLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Resume session in a new window")
    }

    private var subtitleLine: String {
        let age = relativeAge(from: paused.lastActivity)
        if let s = paused.subtitle, !s.isEmpty { return "\(age) · \(s)" }
        return age
    }
}

/// Compact token count like "45k tok", "1.2M tok".
private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM tok", Double(n) / 1_000_000) }
    if n >= 1_000 { return "\(n / 1_000)k tok" }
    return "\(n) tok"
}

/// Compact relative age like "just now", "5m ago", "2h ago", "3d ago".
private func relativeAge(from date: Date) -> String {
    let s = max(0, Date().timeIntervalSince(date))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return "\(Int(s / 86400))d ago"
}

// MARK: - Status dots

private struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .working:
            PulsingDot()
        case .idle:
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
        }
    }
}

private struct PulsingDot: View {
    var body: some View {
        // Clock-driven pulse: unlike a repeatForever animation, this cannot
        // freeze when the menu panel is closed and reopened.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2 * .pi / 1.6) + 1) / 2
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .opacity(0.35 + 0.65 * phase)
        }
    }
}
