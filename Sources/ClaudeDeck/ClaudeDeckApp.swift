import SwiftUI
import AppKit

@main
struct ClaudeDeckApp: App {
    @StateObject private var monitor = SessionMonitor()

    private var workingCount: Int {
        monitor.sessions.reduce(0) { $0 + ($1.status == .working ? 1 : 0) }
    }

    var body: some Scene {
        MenuBarExtra {
            SessionListView(monitor: monitor, terminal: monitor.terminal)
                .frame(width: 300)
        } label: {
            if workingCount > 0 {
                Label("\(workingCount)", systemImage: "rectangle.stack")
            } else {
                Image(systemName: "rectangle.stack")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// AppKit-managed Dock window. Declared imperatively (instead of a SwiftUI
/// `Window` scene) so it never auto-opens at launch and so we can flip the
/// activation policy in lock-step with its visibility.
final class DockWindow: NSObject, NSWindowDelegate {
    static let shared = DockWindow()

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(monitor: SessionMonitor, terminal: TerminalController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        NSApp.setActivationPolicy(.regular)

        if window == nil {
            let root = SessionListView(monitor: monitor, terminal: terminal)
                .frame(width: 320)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "ClaudeDeck"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setContentSize(NSSize(width: 320, height: 440))
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // User closed the window via the red button.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}
