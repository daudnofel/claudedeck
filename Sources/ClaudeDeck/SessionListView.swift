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
        if monitor.sessions.isEmpty {
            Text("No Claude Code sessions running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(monitor.sessions) { session in
                    SessionRow(session: session) {
                        if let wid = session.terminalWindowID {
                            let current = monitor.latestWindows.first { $0.id == wid }?.bounds
                            terminal.focusSession(windowID: wid, tty: session.tty, currentBounds: current)
                        }
                    }
                }
            }
        }
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
    }
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
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 9, height: 9)
            .opacity(pulse ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
