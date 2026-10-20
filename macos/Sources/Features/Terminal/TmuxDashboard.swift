// The Sources folder is a file system synchronized group shared with the
// iOS target, so anything referencing AppKit has to be guarded rather than
// added to the project's exception list.
#if os(macOS)

import AppKit
import SwiftUI
import GhosttyKit

/// What the tmux dashboard shows: the latest snapshot of one hosted
/// session, kept current by `TmuxWindowManager`.
final class TmuxDashboardModel: ObservableObject {
    @Published var sessionName: String = ""
    @Published var windows: [Ghostty.Action.TmuxWindows.Window] = []
    @Published var sessions: [Ghostty.Action.TmuxWindows.Session] = []

    /// Whether the host terminal is ordered out for `tmux-hide-host`.
    @Published var hostHidden: Bool = false
}

/// A window listing the sessions on the tmux server a terminal is attached
/// to and the windows of the session it is on, after iTerm2's tmux
/// dashboard: switch to another session, choose which windows have a tab,
/// bring one forward, or detach.
///
/// Hiding a window keeps it in tmux, running; it only loses its tab. The
/// choice is stored on the window in tmux, so it holds across attaches.
///
/// Everything here asks tmux and waits for its answer rather than changing
/// what is shown first: the model is only ever what tmux last said.
final class TmuxDashboardController: NSWindowController, NSWindowDelegate {
    let model = TmuxDashboardModel()

    /// The surface that ran `tmux -CC`, which is who the core takes
    /// session-wide requests from.
    private weak var hostView: Ghostty.SurfaceView?

    /// Called once the window has closed, so whoever keeps us can let go.
    var onClose: (() -> Void)?

    init(hostView: Ghostty.SurfaceView, manager: TmuxWindowManager) {
        self.hostView = hostView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "tmux Dashboard"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.setFrameAutosaveName("TmuxDashboard")

        super.init(window: window)
        window.delegate = self

        let actions = TmuxDashboardView.Actions(
            switchSession: { [weak hostView] id in
                guard let surface = hostView?.surface else { return }
                _ = ghostty_surface_tmux_switch_session(surface, id)
            },
            setHidden: { [weak hostView] id, hidden in
                guard let surface = hostView?.surface else { return }
                _ = ghostty_surface_tmux_set_window_hidden(surface, id, hidden)
            },
            showWindow: { [weak manager, weak hostView] id in
                guard let hostView else { return }
                manager?.showWindow(id: id, hostedBy: hostView)
            },
            showHost: { [weak manager, weak hostView] in
                guard let hostView else { return }
                manager?.revealHost(hostView)
            },
            refreshSessions: { [weak self] in self?.refreshSessions() },
            detach: { [weak hostView] in hostView?.tmuxDetach(nil) })

        window.contentView = NSHostingView(rootView: TmuxDashboardView(model: model, actions: actions))
        if !window.setFrameUsingName("TmuxDashboard") { window.center() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Show the dashboard, reading the session list afresh: tmux does not
    /// announce windows opening in other sessions, so counts go stale.
    func present() {
        refreshSessions()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ action: Ghostty.Action.TmuxWindows, hostHidden: Bool) {
        model.sessionName = action.sessionName
        model.windows = action.windows
        model.sessions = action.sessions
        model.hostHidden = hostHidden
    }

    private func refreshSessions() {
        guard let surface = hostView?.surface else { return }
        _ = ghostty_surface_tmux_list_sessions(surface)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

struct TmuxDashboardView: View {
    @ObservedObject var model: TmuxDashboardModel
    let actions: Actions

    struct Actions {
        let switchSession: (Int) -> Void
        let setHidden: (Int, Bool) -> Void
        let showWindow: (Int) -> Void
        let showHost: () -> Void
        let refreshSessions: () -> Void
        let detach: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if model.sessions.isEmpty {
                        Text("Reading sessions…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sessions, id: \.id) { session in
                        sessionRow(session)
                    }
                } header: {
                    HStack {
                        Text("Sessions")
                        Spacer()
                        Button {
                            actions.refreshSessions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Read the session list again")
                    }
                }

                Section {
                    ForEach(model.windows, id: \.id) { window in
                        windowRow(window)
                    }
                } header: {
                    Text("Windows in “\(model.sessionName)”")
                } footer: {
                    Text("A hidden window keeps running in tmux but has no tab here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if model.hostHidden {
                    Button("Show Host Terminal") { actions.showHost() }
                }
                Spacer()
                Button("Detach") { actions.detach() }
            }
            .padding()
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    private func sessionRow(_ session: Ghostty.Action.TmuxWindows.Session) -> some View {
        let current = session.name == model.sessionName
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                Text(sessionDetail(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if current {
                Text("Current")
                    .foregroundStyle(.secondary)
            } else {
                Button("Attach") { actions.switchSession(session.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tmux-session-\(session.id)")
    }

    private func sessionDetail(_ session: Ghostty.Action.TmuxWindows.Session) -> String {
        let windows = session.windows == 1 ? "1 window" : "\(session.windows) windows"
        switch session.attached {
        case 0: return windows
        case 1: return "\(windows), 1 client attached"
        default: return "\(windows), \(session.attached) clients attached"
        }
    }

    private func windowRow(_ window: Ghostty.Action.TmuxWindows.Window) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { !window.hidden },
                set: { actions.setHidden(window.id, !$0) }
            )) {
                Text(window.name.isEmpty ? "Window @\(window.id)" : window.name)
                    .foregroundStyle(window.hidden ? .secondary : .primary)
            }
            .help(window.hidden ? "Give this window a tab again" : "Hide this window's tab; it keeps running in tmux")
            Spacer()
            if window.active {
                Text("Current")
                    .foregroundStyle(.secondary)
            }
            if !window.hidden {
                Button("Show") { actions.showWindow(window.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tmux-window-\(window.id)")
    }
}

#endif
