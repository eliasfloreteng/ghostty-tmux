// The Sources folder is a file system synchronized group shared with the
// iOS target, so anything referencing AppKit or TerminalController has to
// be guarded rather than added to the project's exception list.
#if os(macOS)

import AppKit
import GhosttyKit

/// Creates and maintains native windows for tmux control mode windows.
///
/// Observes `.ghosttyDidUpdateTmuxWindows`, which the
/// `GHOSTTY_ACTION_TMUX_WINDOWS` handler posts with a deep copied payload
/// and the hosting surface as the notification object.
///
/// tmux sends the whole window list on every change rather than a delta,
/// so this diffs it against what is already on screen: windows and panes
/// that are new are created, ones that already exist are reused, and
/// anything tmux stopped mentioning is closed.
///
/// Reuse is the point. Rebuilding a pane's surface when the layout changes
/// would throw away its terminal and start it over, so panes are looked up
/// by tmux pane id and only their arrangement is rebuilt.
class TmuxWindowManager {
    /// tmux window and pane ids are only unique within one control mode
    /// session, so they are qualified by the surface hosting it.
    private struct Key: Hashable {
        let host: ObjectIdentifier
        let id: Int
    }

    /// What we keep for each tmux window on screen.
    private final class WindowEntry {
        /// Weakly held: the user can close one of these windows
        /// themselves, and we should not keep it alive or resurrect it.
        weak var controller: TerminalController?

        /// tmux's active pane in this window as of the last snapshot, so
        /// a change can be told from tmux repeating itself.
        var activePaneId: Int?

        /// A pane to focus once the window is key. See `focus(_:in:)`.
        weak var pendingFocus: Ghostty.SurfaceView?

        /// Whether tmux is on this window, as of the last snapshot.
        var isActive: Bool = false

        init(controller: TerminalController) {
            self.controller = controller
        }
    }

    private struct WeakSurface {
        weak var value: Ghostty.SurfaceView?
    }

    private var windows: [Key: WindowEntry] = [:]
    private var panes: [Key: WeakSurface] = [:]

    /// Hosts one of whose windows closed while it was key, since their
    /// last snapshot. See `sessionEmptied`.
    private var closedWhileKey: Set<ObjectIdentifier> = []

    /// tmux.conf errors waiting to be shown together. See `tmuxConfigError`.
    private struct ConfigErrors {
        weak var host: Ghostty.SurfaceView?
        var errors: [String] = []
        var presentation: DispatchWorkItem?
    }
    private var configErrors: [ObjectIdentifier: ConfigErrors] = [:]

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyDidUpdateTmuxWindows(_:)),
            name: .ghosttyDidUpdateTmuxWindows,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyTmuxNotice(_:)),
            name: .ghosttyTmuxNotice,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func ghosttyDidUpdateTmuxWindows(_ notification: Notification) {
        guard let hostView = notification.object as? Ghostty.SurfaceView else { return }
        guard let action = notification.userInfo?[
            Notification.Name.TmuxWindowsKey
        ] as? Ghostty.Action.TmuxWindows else { return }

        let host = ObjectIdentifier(hostView)

        // Before anything that needs the host to still be alive: a
        // session ending is often why it is not.
        if action.windows.isEmpty {
            sessionEmptied(hostView, sessionName: action.sessionName)
            return
        }

        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let ghostty = appDelegate.ghostty
        guard let app = ghostty.app else { return }
        guard let hostSurface = hostView.surface else { return }

        var liveWindows: Set<Key> = []
        var livePanes: Set<Key> = []

        for window in action.windows {
            liveWindows.insert(Key(host: host, id: window.id))
            for node in window.nodes where node.kind == .pane {
                livePanes.insert(Key(host: host, id: node.paneId))
            }
        }

        for (index, window) in action.windows.enumerated() {
            guard !window.nodes.isEmpty else { continue }

            guard let root = node(
                for: window,
                at: 0,
                host: host,
                app: app,
                hostSurface: hostSurface
            ) else {
                Ghostty.logger.warning(
                    "could not build a layout for tmux window id=\(window.id)")
                continue
            }

            // Zoom renders one pane in place of the whole tree. Every
            // other pane is still in `root` and still alive: this picks
            // which node is drawn, it does not prune anything.
            let zoomed: SplitTree<Ghostty.SurfaceView>.Node? = {
                guard let paneId = window.zoomedPaneId,
                      let view = panes[Key(host: host, id: paneId)]?.value
                else { return nil }

                // Against the tree being built, not the one on screen.
                return root.node(view: view)
            }()

            let tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: zoomed)
            let key = Key(host: host, id: window.id)

            if let entry = windows[key], let controller = entry.controller {
                // Only touch the window if the arrangement actually
                // changed. tmux reports the layout on every notification,
                // including ones that changed nothing, and reassigning the
                // tree tears views out of the hierarchy and puts them back.
                // SplitTree is not Equatable, but its nodes are.
                //
                // Zoom has to be part of that comparison. tmux's
                // window_layout does not change when a pane zooms -- that
                // is the whole point of it -- so the roots compare equal
                // and a zoom toggle would never reach the screen.
                if controller.surfaceTree.root != tree.root ||
                    controller.surfaceTree.zoomed != tree.zoomed {
                    controller.surfaceTree = tree
                    keepFocusInWindow(window, of: entry, host: host)
                }
                setTitle(controller, window.name)
                entry.isActive = window.active
                followActivePane(window, of: entry, host: host)
                continue
            }

            // The first tmux window for a host gets a window of its own;
            // every one after it opens as a tab beside it.
            //
            // Both halves matter. A control mode session is its own
            // thing, so `tmux -CC` should not drop more tabs onto
            // whatever window happened to launch it. But a tmux window
            // *is* what tmux calls a tab, so the second one onwards
            // belongs beside the first rather than scattered across the
            // desktop -- which is also how the GTK side shows them.
            //
            // Opened as a tab rather than opened as a window and then
            // joined: `newWindow` sizes the window to the tree, cascades
            // it and shows it, so joining afterwards meant watching a
            // window appear offset down and to the right and then get
            // absorbed. `newTab` puts it in the group before anything is
            // presented, and handles the fullscreen rules while it is
            // there.
            let controller = newController(
                ghostty: ghostty,
                tree: tree,
                parent: tabParent(action.windows, before: index, host: host))
            controller.isTmuxWindow = true
            setTitle(controller, window.name)
            let entry = WindowEntry(controller: controller)
            entry.isActive = window.active
            windows[key] = entry

            // Where the user left the session, rather than whichever pane
            // AppKit happens to focus first.
            followActivePane(window, of: entry, host: host)
        }

        prune(liveWindows: liveWindows, livePanes: livePanes, host: host)
        selectActiveWindow(action.windows, host: host)
        setHostedSession(hostView, action.sessionName)

        // The session is still going, so whatever closed was not it.
        closedWhileKey.remove(host)
    }

    /// A snapshot with no windows: the session changed or ended.
    ///
    /// Either way, every window of the session goes. tmux has already
    /// let go of them -- they are another session's, or nobody's -- so
    /// this is not the user closing anything, and nothing asks. The
    /// panes' own surfaces are closing too, without asking, since the
    /// core marks them exited; whichever gets there first wins.
    ///
    /// When the session ended and the user was in it, they are taken back
    /// to where they started it: the host is the one surface of theirs
    /// that is still about this session, and otherwise AppKit picks
    /// whatever window happens to be next. A session change instead
    /// opens the new session's windows straight away, which is where
    /// they should be.
    private func sessionEmptied(_ hostView: Ghostty.SurfaceView, sessionName: String) {
        let ended = sessionName.isEmpty
        let host = ObjectIdentifier(hostView)

        // The panes close themselves when the session ends, and that can
        // reach us before this does, taking a key window with it.
        let wasInSession = closedWhileKey.remove(host) != nil || windows.contains { key, entry in
            key.host == host && (entry.controller?.window?.isKeyWindow ?? false)
        }

        prune(liveWindows: [], livePanes: [], host: host)
        closedWhileKey.remove(host)
        setHostedSession(hostView, ended ? nil : sessionName)

        guard ended, wasInSession else { return }
        guard let controller = hostView.window?.windowController as? BaseTerminalController else { return }
        controller.focusSurface(hostView)
    }

    // MARK: Notices

    /// Show what tmux has to tell the user.
    ///
    /// A normal tmux client puts these on its status line, which we do
    /// not have, and nothing else would show them: a mistake in tmux.conf,
    /// a split tmux refused, the reason a session ended would all go
    /// unseen. Each is shown the way it deserves:
    ///
    /// - A message or a failed command is a passing notice over the pane
    ///   the user is in, which is where the status line would have been
    ///   and where they just did whatever failed.
    /// - Configuration errors are collected and shown together in one
    ///   alert: they arrive in a burst while the session attaches, one
    ///   per error, and say the session may not be set up as intended.
    /// - The reason a session ended goes on the host, since the session's
    ///   own windows are about to close.
    @objc private func ghosttyTmuxNotice(_ notification: Notification) {
        guard let hostView = notification.object as? Ghostty.SurfaceView else { return }
        guard let notice = notification.userInfo?[
            Notification.Name.TmuxNoticeKey
        ] as? Ghostty.Action.TmuxNotice else { return }

        switch notice.kind {
        case .message:
            noticeTarget(hostedBy: hostView).showTransientNotice("tmux: \(notice.text)")

        case .commandError:
            noticeTarget(hostedBy: hostView).showTransientNotice(
                "tmux: \(notice.text)",
                level: .error,
                duration: 8)

        case .exit:
            hostView.showTransientNotice("tmux: \(notice.text)", duration: 8)

        case .configError:
            tmuxConfigError(notice.text, hostedBy: hostView)
        }
    }

    /// Where a notice for the session hosted by `hostView` goes: the pane
    /// the user is in if they are in the session, else the pane in the
    /// window tmux is on, else the host.
    private func noticeTarget(hostedBy hostView: Ghostty.SurfaceView) -> Ghostty.SurfaceView {
        let host = ObjectIdentifier(hostView)
        let entries = windows.filter { $0.key.host == host }.map(\.value)
        let entry = entries.first { $0.controller?.window?.isKeyWindow ?? false }
            ?? entries.first { $0.isActive }
        guard let controller = entry?.controller else { return hostView }

        if let focused = controller.focusedSurface, controller.surfaceTree.contains(focused) {
            return focused
        }
        return controller.surfaceTree.first ?? hostView
    }

    /// Collect a tmux.conf error, and show what has been collected once
    /// they stop arriving.
    private func tmuxConfigError(_ text: String, hostedBy hostView: Ghostty.SurfaceView) {
        let host = ObjectIdentifier(hostView)
        var pending = configErrors[host] ?? ConfigErrors(host: hostView)
        pending.errors.append(text)
        pending.presentation?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.presentConfigErrors(host: host)
        }
        pending.presentation = work
        configErrors[host] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func presentConfigErrors(host: ObjectIdentifier) {
        guard let pending = configErrors.removeValue(forKey: host),
              let hostView = pending.host,
              !pending.errors.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = pending.errors.count == 1
            ? "tmux Configuration Error"
            : "tmux Configuration Errors"
        alert.informativeText = """
            tmux reported a problem loading its configuration, so the \
            session may not be set up as intended.

            \(pending.errors.joined(separator: "\n"))
            """
        alert.addButton(withTitle: "OK")

        // A sheet on a window of the session if the user is in one, which
        // after attaching they usually are, otherwise on the host's.
        let window = noticeTarget(hostedBy: hostView).window ?? hostView.window
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            // Busy with a sheet of its own, or nowhere to go. Not worth
            // an app modal alert over.
            hostView.showTransientNotice(
                "tmux: \(pending.errors.joined(separator: "; "))",
                level: .error,
                duration: 10)
        }
    }

    // MARK: Host

    /// Tell the host which session it is hosting, or that it is not any
    /// more. It shows that in place of its terminal.
    private func setHostedSession(_ hostView: Ghostty.SurfaceView, _ name: String?) {
        if hostView.hostedTmuxSession != name { hostView.hostedTmuxSession = name }
    }

    /// Bring the session hosted by `hostView` forward: the window tmux is
    /// on, or failing that any of the session's windows.
    func showWindows(hostedBy hostView: Ghostty.SurfaceView) {
        let host = ObjectIdentifier(hostView)
        let candidates = windows.filter { $0.key.host == host }
        let entry = candidates.first { $0.value.isActive }?.value ?? candidates.first?.value
        guard let window = entry?.controller?.window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Bring forward the tab for the window tmux is currently on.
    ///
    /// tmux tracks a current window per session, and it moves when
    /// anyone moves it -- another client, a script, a binding typed in a
    /// pane. When it moves for a reason that did not come from us, the
    /// tab on screen and the window tmux thinks the user is on have come
    /// apart, and tmux's answer is the right one.
    ///
    /// Only when the group is already frontmost. tmux says nothing about
    /// whether ghostty should come forward, and a background session
    /// changing windows is not a reason to interrupt whatever the user
    /// is doing in another app -- or another window of this one.
    ///
    /// Selecting a tab that is already selected is not free: AppKit
    /// still runs the tab switch, so the check matters.
    private func selectActiveWindow(
        _ windows: [Ghostty.Action.TmuxWindows.Window],
        host: ObjectIdentifier
    ) {
        guard let active = windows.first(where: { $0.active }) else { return }
        guard let controller = self.windows[Key(host: host, id: active.id)]?.controller,
              let window = controller.window else { return }
        guard let group = window.tabGroup else { return }
        guard group.selectedWindow !== window else { return }
        guard group.windows.contains(where: { $0.isKeyWindow }) else { return }

        group.selectedWindow = window
    }

    /// Put focus back on a surviving pane when the focused one is gone.
    ///
    /// Closing a split locally hands focus to a neighbour, but a tmux
    /// pane does not close: the layout it was in is replaced wholesale,
    /// so nothing runs that logic and the window is left focused on a
    /// view that is no longer in it.
    ///
    /// The survivor is tmux's active pane, which is where tmux itself
    /// moves to when a pane goes; the first pane listed only stands in
    /// when tmux has not said.
    private func keepFocusInWindow(
        _ window: Ghostty.Action.TmuxWindows.Window,
        of entry: WindowEntry,
        host: ObjectIdentifier
    ) {
        guard let controller = entry.controller else { return }
        if let focused = controller.focusedSurface,
           controller.surfaceTree.contains(focused) { return }

        let candidates = [window.activePaneId].compactMap { $0 } +
            window.nodes.filter { $0.kind == .pane }.map(\.paneId)
        for paneId in candidates {
            guard let view = panes[Key(host: host, id: paneId)]?.value,
                  controller.surfaceTree.contains(view) else { continue }
            focus(view, in: entry)
            return
        }
    }

    /// Move focus to tmux's active pane when tmux moves it, or when the
    /// window is new.
    ///
    /// tmux tracks an active pane per window, and it moves when anyone
    /// moves it: another client, a binding typed in a pane, a split
    /// (the new pane is made active), a pane closing. A repeat of the
    /// same pane is not a move, and is left alone so the user can be
    /// elsewhere in the window until tmux has heard about it; our own
    /// focus changes are told to tmux, and the core does not echo them.
    private func followActivePane(
        _ window: Ghostty.Action.TmuxWindows.Window,
        of entry: WindowEntry,
        host: ObjectIdentifier
    ) {
        let previous = entry.activePaneId
        entry.activePaneId = window.activePaneId
        guard let paneId = window.activePaneId, paneId != previous else { return }
        guard let view = panes[Key(host: host, id: paneId)]?.value else { return }
        focus(view, in: entry)
    }

    /// Focus a pane of a tmux window, now if the window is key and
    /// otherwise once it becomes key.
    ///
    /// Waiting matters. A surface reports focus to the core as soon as it
    /// becomes first responder, key window or not, and focusing a tmux
    /// pane selects its window in tmux as well. Doing that in a
    /// background tab would make it tmux's current window, which we then
    /// follow by bringing the tab forward: a pane moving in another
    /// window would pull the user over to it. That includes a window
    /// that was key when this was asked and is not any more by the time
    /// the view is in it, which is every tab but the last when several
    /// are created together.
    private func focus(_ view: Ghostty.SurfaceView, in entry: WindowEntry) {
        entry.pendingFocus = view
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.applyPendingFocus(entry)
        }
    }

    private func applyPendingFocus(_ entry: WindowEntry, attempt: Int = 0) {
        guard let view = entry.pendingFocus, let controller = entry.controller else { return }
        guard controller.surfaceTree.contains(view) else {
            entry.pendingFocus = nil
            return
        }

        // Not key: it stays pending until windowDidBecomeKey.
        guard let window = controller.window, window.isKeyWindow else { return }

        // A tree that was only just assigned is not in the window until
        // SwiftUI has laid it out.
        guard view.window === window else {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.applyPendingFocus(entry, attempt: attempt + 1)
            }
            return
        }

        entry.pendingFocus = nil
        guard window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isKeyWindow else { return }
        guard let key = windows.first(where: { $0.value.controller?.window === window })?.key else { return }
        closedWhileKey.insert(key.host)
    }

    /// Apply a focus change that was waiting for its window to be key.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let entry = windows.values.first(where: { $0.controller?.window === window }),
              entry.pendingFocus != nil else { return }

        // A click in the window is the user choosing where to be, and it
        // is what made the window key. tmux hears about that choice as
        // soon as the click lands, so it wins over what tmux said before.
        if let event = NSApp.currentEvent,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            entry.pendingFocus = nil
            return
        }

        // After the controller's own handling of becoming key, which may
        // put focus back on whatever the window last had.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.applyPendingFocus(entry)
        }
    }

    /// The controller for a tmux window: a tab going in after `parent`,
    /// or a window of its own when the host has nothing to sit beside.
    ///
    /// `newTab` returns nil only when it has told the user why it cannot
    /// make one, which is non-native fullscreen. The tmux window exists
    /// either way and has to go somewhere, so it gets a window.
    private func newController(
        ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        parent: NSWindow?
    ) -> TerminalController {
        if let parent,
           let controller = TerminalController.newTab(
               ghostty,
               from: parent,
               withSurfaceTree: tree) {
            return controller
        }

        return TerminalController.newWindow(ghostty, tree: tree)
    }

    /// The window a new tab for `windows[index]` should go in after, or
    /// nil if this host has nothing on screen yet.
    ///
    /// Asked rather than remembered, because a remembered one goes stale:
    /// the tmux window holding it can close while others stay open, and
    /// the next window to arrive would then have nothing to join and
    /// would come up on its own.
    ///
    /// Found by walking tmux's order rather than by taking any window of
    /// this host. Any of them finds the right tab group, but `newTab`
    /// puts the tab in *after the one it is given*, and `windows` is a
    /// dictionary -- so picking whichever came out first dropped new tabs
    /// at an arbitrary position in the bar.
    private func tabParent(
        _ windows: [Ghostty.Action.TmuxWindows.Window],
        before index: Int,
        host: ObjectIdentifier
    ) -> NSWindow? {
        // The nearest window before this one that is already on screen.
        // Going in after it is what lines our tabs up with tmux's order.
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return window }
        }

        // Nothing before it, so settle for finding the group: the tab
        // lands one place later than tmux has it. Only reachable when a
        // window appears before ones already on screen, which needs a
        // lower index to be freed up and reused.
        for i in stride(from: index + 1, to: windows.count, by: 1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return window }
        }

        return nil
    }

    private func liveWindow(id: Int, host: ObjectIdentifier) -> NSWindow? {
        guard let window = windows[Key(host: host, id: id)]?.controller?.window,
              window.isVisible else { return nil }
        return window
    }

    /// Show the tmux window's name as the window title.
    ///
    /// tmux owns what a tmux window is called, so this goes in as the
    /// override: the surface titles underneath are the shell's idea of a
    /// title, which is a different thing. Assigning only on a change
    /// keeps this off the main thread's work list for the common case
    /// where tmux re-reports a layout that did not move.
    private func setTitle(_ controller: TerminalController, _ name: String) {
        let wanted = name.isEmpty ? nil : name
        if controller.titleOverride != wanted {
            controller.titleOverride = wanted
        }
    }

    /// Close the windows for tmux windows that are gone, and forget panes
    /// that are gone. Only touches state belonging to this host, so two
    /// tmux sessions in one app do not disturb each other.
    private func prune(
        liveWindows: Set<Key>,
        livePanes: Set<Key>,
        host: ObjectIdentifier
    ) {
        for (key, entry) in windows {
            guard key.host == host else { continue }
            if liveWindows.contains(key) {
                // Drop entries whose window the user closed themselves, so
                // a later layout can build a fresh one.
                if entry.controller == nil { windows.removeValue(forKey: key) }
                continue
            }

            // Just this tab. closeWindowImmediately takes the whole tab
            // group with it, and these windows are tabs of one another,
            // so closing one tmux window would have closed every other
            // one along with it. Nothing is registered for undo: a tmux
            // window has no undo manager (see `isTmuxWindow`).
            entry.controller?.closeTabImmediately()
            windows.removeValue(forKey: key)
        }

        for (key, entry) in panes {
            guard key.host == host else { continue }
            if livePanes.contains(key) && entry.value != nil { continue }

            // The surface itself is released by the tree that no longer
            // holds it; all we owe is forgetting it.
            panes.removeValue(forKey: key)
        }
    }

    /// Build the split tree for one node of a tmux layout.
    ///
    /// tmux splits can have any number of children; a split tree is binary,
    /// so a run of children becomes a chain of two way splits leaning left.
    /// Ratios come from the children's own sizes rather than the parent's,
    /// because a tmux split spends a cell on the divider between each pair
    /// and so the children do not add up to the parent.
    private func node(
        for window: Ghostty.Action.TmuxWindows.Window,
        at index: Int,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard window.nodes.indices.contains(index) else { return nil }
        let n = window.nodes[index]

        switch n.kind {
        case .pane:
            guard let view = surface(
                paneId: n.paneId,
                host: host,
                app: app,
                hostSurface: hostSurface
            ) else { return nil }
            return .leaf(view: view)

        case .horizontal, .vertical:
            let direction: SplitTree<Ghostty.SurfaceView>.Direction =
                n.kind == .horizontal ? .horizontal : .vertical
            return chain(
                window: window,
                children: Array(n.children),
                direction: direction,
                host: host,
                app: app,
                hostSurface: hostSurface)
        }
    }

    private func chain(
        window: Ghostty.Action.TmuxWindows.Window,
        children: [Int],
        direction: SplitTree<Ghostty.SurfaceView>.Direction,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard let first = children.first else { return nil }

        let head = node(
            for: window,
            at: first,
            host: host,
            app: app,
            hostSurface: hostSurface)
        let rest = Array(children.dropFirst())
        if rest.isEmpty { return head }

        guard let head else { return nil }
        guard let tail = chain(
            window: window,
            children: rest,
            direction: direction,
            host: host,
            app: app,
            hostSurface: hostSurface
        ) else { return head }

        // Against what is left rather than the whole span, so the second
        // cut of three equal panes is a half and not a third.
        let span = { (i: Int) -> Int in
            guard window.nodes.indices.contains(i) else { return 0 }
            let node = window.nodes[i]
            return direction == .horizontal ? node.width : node.height
        }
        let headSpan = span(first)
        let total = headSpan + rest.reduce(0) { $0 + span($1) }
        let ratio = total > 0 ? Double(headSpan) / Double(total) : 0.5

        return .split(.init(
            direction: direction,
            ratio: ratio,
            left: head,
            right: tail))
    }

    /// The surface displaying one tmux pane, made if we do not have it.
    ///
    /// Every surface consumes exactly one router reference, so a fresh one
    /// is taken per surface and ownership passes to the surface config.
    private func surface(
        paneId: Int,
        host: ObjectIdentifier,
        app: ghostty_app_t,
        hostSurface: ghostty_surface_t
    ) -> Ghostty.SurfaceView? {
        let key = Key(host: host, id: paneId)
        if let existing = panes[key]?.value { return existing }

        guard let router = ghostty_surface_tmux_router(hostSurface) else {
            Ghostty.logger.warning("no tmux router for the hosting surface")
            return nil
        }

        var config = Ghostty.SurfaceConfiguration()
        config.tmuxRouter = router
        config.tmuxPaneId = paneId

        let view = Ghostty.SurfaceView(app, baseConfig: config)
        panes[key] = .init(value: view)
        return view
    }
}

#endif
