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

    /// Panes the user dragged out of their window, with where they were
    /// dropped. See `breakOut(_:at:)`.
    private struct BrokenOut {
        let position: NSPoint?
        let at: Date
    }
    private var brokenOut: [Key: BrokenOut] = [:]

    /// Each host's windows in tmux's order, as of its last snapshot.
    private var windowOrder: [ObjectIdentifier: [Int]] = [:]

    /// An order we asked tmux for by moving a window, and until when we
    /// wait for it rather than put the tabs back. See `tabsDidReorder`.
    private struct PendingOrder {
        let order: [Int]
        let until: Date
    }
    private var pendingOrder: [ObjectIdentifier: PendingOrder] = [:]

    /// Each host's tmux status line, for sessions that mirror it. See
    /// `ghosttyTmuxStatus`.
    private var statuses: [ObjectIdentifier: Ghostty.Action.TmuxStatus] = [:]

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyTmuxStatus(_:)),
            name: .ghosttyTmuxStatus,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tabsDidReorder(_:)),
            name: .ghosttyTabsDidReorder,
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

        // tmux's current window first: it is the one tab to be shown, and
        // every other tab is placed relative to one already on screen. See
        // `tabParent`.
        let order = action.windows.indices.sorted { a, b in
            action.windows[a].active && !action.windows[b].active
        }

        for index in order {
            let window = action.windows[index]
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
                setTitle(controller, window)
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
            //
            // Only tmux's current window is selected. Any other is put in
            // the tab bar without being shown: showing it would make it
            // key, its pane would gain focus, and a pane gaining focus
            // tells tmux the user is there -- making it tmux's current
            // window, which the tab bar then follows. A session switched
            // to, or a window opened with `new-window -d`, would pull the
            // user into whichever tab happened to be built last.
            // A pane the user dragged out of its window comes back in a
            // tmux window of its own, and that goes where it was dropped,
            // as a window: the same as dragging out an ordinary split.
            // Only for a little while: tmux may have refused, and the same
            // pane breaking out later by other means is a new tab again.
            let breakOut = window.nodes.lazy
                .filter { $0.kind == .pane }
                .compactMap { self.brokenOut.removeValue(forKey: Key(host: host, id: $0.paneId)) }
                .first { $0.at.timeIntervalSinceNow > -5 }

            let controller = newController(
                ghostty: ghostty,
                tree: tree,
                placement: breakOut != nil ? nil : tabParent(action.windows, of: index, host: host),
                position: breakOut?.position,
                select: window.active,
                hostSize: hostView.window.map { $0.contentRect(forFrameRect: $0.frame).size },
                // Where focus goes when the tab is first shown, which for
                // a tab made in the background is when the user picks it.
                // Otherwise it is the first pane, and focusing that tells
                // tmux the user moved there, over the pane tmux had active.
                initialFocus: window.activePaneId.flatMap { panes[Key(host: host, id: $0)]?.value })
            controller.isTmuxWindow = true
            controller.tmuxStatus = statuses[host]
            setTitle(controller, window)

            let entry = WindowEntry(controller: controller)
            entry.isActive = window.active
            windows[key] = entry

            // Where the user left the session, rather than whichever pane
            // AppKit happens to focus first.
            followActivePane(window, of: entry, host: host)
        }

        prune(liveWindows: liveWindows, livePanes: livePanes, host: host)
        windowOrder[host] = action.windows.map(\.id)
        arrangeTabs(host: host)
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
        windowOrder.removeValue(forKey: host)
        pendingOrder.removeValue(forKey: host)

        // A session switched to keeps the status line: it is the
        // client's, and tmux only says again what changed.
        if ended { statuses.removeValue(forKey: host) }
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

        case .commandOutput:
            tmuxCommandOutput(notice.text, hostedBy: hostView)
        }
    }

    /// tmux's status line changed: show it on every window of the session.
    ///
    /// Kept per host as well, for windows that open later, since tmux only
    /// says what changed and when.
    @objc private func ghosttyTmuxStatus(_ notification: Notification) {
        guard let hostView = notification.object as? Ghostty.SurfaceView else { return }
        guard let status = notification.userInfo?[
            Notification.Name.TmuxStatusKey
        ] as? Ghostty.Action.TmuxStatus else { return }

        let host = ObjectIdentifier(hostView)
        statuses[host] = status
        for (key, entry) in windows where key.host == host {
            guard let controller = entry.controller, controller.tmuxStatus != status else { continue }
            controller.tmuxStatus = status
        }
    }

    /// Show what a command line the user typed printed.
    ///
    /// A line or so is a passing notice, like a message. Anything longer
    /// -- `list-sessions`, `show-options` -- is something to read, so it
    /// goes in a sheet with room for it and text that can be selected
    /// and copied.
    private func tmuxCommandOutput(_ text: String, hostedBy hostView: Ghostty.SurfaceView) {
        let target = noticeTarget(hostedBy: hostView)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count == 1 && text.count <= 120 {
            target.showTransientNotice("tmux: \(text)", duration: 8)
            return
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = text

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "tmux"
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "OK")

        if let window = target.window ?? hostView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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

    // MARK: Moving panes and windows

    /// Take a tmux pane the user dragged out of its window into a tmux
    /// window of its own, opened as a window where it was dropped.
    ///
    /// Nothing moves here: tmux breaks the pane out, and its window list
    /// brings the new window. All this does is remember that the window
    /// holding this pane should be a window rather than a tab. tmux keeps
    /// the pane's id, which is how it is recognised.
    func breakOut(_ view: Ghostty.SurfaceView, at position: NSPoint?) {
        guard let surface = view.surface else { return }
        guard let key = panes.first(where: { $0.value.value === view })?.key else { return }
        guard ghostty_surface_tmux_break_pane(surface) else { return }
        brokenOut[key] = BrokenOut(position: position, at: Date())
    }

    /// The tmux window ids of this host's tabs in `group`, in the order
    /// the tabs are in.
    private func tabOrder(of group: NSWindowTabGroup, host: ObjectIdentifier) -> [Int] {
        group.windows.compactMap { window in
            windows.first { $0.key.host == host && $0.value.controller?.window === window }?.key.id
        }
    }

    /// Put this host's tabs in tmux's order, in every tab group holding
    /// them.
    ///
    /// A tmux window's place in the tab bar is its place in tmux's window
    /// order, and tmux's order moves for reasons that are not ours: a
    /// `move_tab` sent to tmux, another client, a script. Tabs dragged into
    /// a window of their own, or into another window's group, are left
    /// where they are: tmux has no idea of native windows, only of order,
    /// so only the order within each group is tmux's to decide.
    ///
    /// Not while an order we asked for is on its way. tmux does not say
    /// when windows move, so the snapshots in between still have the old
    /// one, and following them would drag the tab the user just dropped
    /// back for a moment.
    private func arrangeTabs(host: ObjectIdentifier) {
        guard let order = windowOrder[host] else { return }
        if let pending = pendingOrder[host] {
            if pending.order != order && pending.until > Date() { return }
            pendingOrder.removeValue(forKey: host)
        }

        let groups = windows
            .filter { $0.key.host == host }
            .compactMap { $0.value.controller?.window?.tabGroup }
        var seen: Set<ObjectIdentifier> = []
        for group in groups where seen.insert(ObjectIdentifier(group)).inserted {
            let ours = tabOrder(of: group, host: host)
            let wanted = order.filter { ours.contains($0) }
            guard ours != wanted else { continue }

            let selected = group.selectedWindow
            let key = group.windows.first { $0.isKeyWindow }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0

            // Each window after the one tmux has before it. Anything that
            // is not one of ours stays where it was relative to its
            // neighbours.
            for (previous, id) in zip(wanted, wanted.dropFirst()) {
                guard let before = windows[Key(host: host, id: previous)]?.controller?.window,
                      let window = windows[Key(host: host, id: id)]?.controller?.window,
                      let beforeIndex = group.windows.firstIndex(of: before),
                      let index = group.windows.firstIndex(of: window),
                      index < beforeIndex else { continue }
                group.removeWindow(window)
                before.addTabbedWindowSafely(window, ordered: .above)
            }

            if let selected, group.selectedWindow !== selected { group.selectedWindow = selected }
            key?.makeKey()
            NSAnimationContext.endGrouping()
        }
    }

    /// The user dragged tabs around: tell tmux where this host's windows
    /// went.
    ///
    /// Only for a tab dragged with the mouse. The tab bar also reorders
    /// when we arrange it to follow tmux, and that must not be sent back
    /// as a move: tmux is already there.
    ///
    /// A drag moves one tab, and that is the move asked of tmux: the tab
    /// goes just after the one now before it (or before the one after it,
    /// when it is first), worked out in tmux's whole window order, since
    /// windows of the session in other native windows are part of it too.
    /// It is sent as `move_tab`, which on a tmux pane moves its window.
    @objc private func tabsDidReorder(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              [.leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
        guard let group = (notification.object as? NSWindow)?.tabGroup else { return }

        let hosts = Set(windows.keys.map(\.host))
        for host in hosts {
            guard let order = windowOrder[host] else { continue }
            let tabs = tabOrder(of: group, host: host)
            let tmux = order.filter { tabs.contains($0) }
            guard tabs != tmux, let moved = Self.movedWindow(from: tmux, to: tabs) else { continue }

            guard let from = order.firstIndex(of: moved),
                  let at = tabs.firstIndex(of: moved) else { continue }
            let to: Int
            if at > 0, let before = order.firstIndex(of: tabs[at - 1]) {
                to = before < from ? before + 1 : before
            } else if at + 1 < tabs.count, let after = order.firstIndex(of: tabs[at + 1]) {
                to = after > from ? after - 1 : after
            } else {
                continue
            }
            guard to != from else { continue }

            guard let controller = windows[Key(host: host, id: moved)]?.controller,
                  let surface = (controller.focusedSurface ?? controller.surfaceTree.first)?.surface
            else { continue }

            var expected = order
            expected.remove(at: from)
            expected.insert(moved, at: to)
            pendingOrder[host] = PendingOrder(order: expected, until: Date().addingTimeInterval(2))

            let action = "move_tab:\(to - from)"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                Ghostty.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }
    }

    /// The one window whose move turns `old` into `new`, if one does.
    /// Both hold the same windows.
    static func movedWindow(from old: [Int], to new: [Int]) -> Int? {
        guard old.count == new.count,
              let i = old.indices.first(where: { old[$0] != new[$0] }) else { return nil }

        // Moved back to here from later on, or moved on from here.
        for candidate in [new[i], old[i]] {
            var moved = old
            guard let from = moved.firstIndex(of: candidate),
                  let to = new.firstIndex(of: candidate) else { continue }
            moved.remove(at: from)
            moved.insert(candidate, at: to)
            if moved == new { return candidate }
        }
        return nil
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
        guard let paneId = window.activePaneId else {
            entry.activePaneId = nil
            return
        }
        guard paneId != entry.activePaneId else { return }

        // Not built yet: tmux can name a new pane active before the layout
        // that holds it arrives (a split does exactly this). Recorded only
        // once it can be acted on, or the snapshot that brings the pane
        // would look like a repeat and the move would never happen.
        guard let view = panes[Key(host: host, id: paneId)]?.value else { return }
        entry.activePaneId = paneId
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
    ///
    /// The controller is told straight away, though: its focused surface
    /// is what it, and the terminal view appearing for the first time,
    /// put focus back on when the window becomes key. Left on the pane
    /// tmux had active before, that would move focus there -- and tmux
    /// with it -- after this had moved it to the right one.
    private func focus(_ view: Ghostty.SurfaceView, in entry: WindowEntry) {
        if let controller = entry.controller,
           controller.surfaceTree.contains(view),
           !(controller.window?.isKeyWindow ?? false) {
            controller.focusedSurface = view
        }
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
        placement: (window: NSWindow, ordered: NSWindow.OrderingMode)?,
        position: NSPoint? = nil,
        select: Bool,
        hostSize: CGSize?,
        initialFocus: Ghostty.SurfaceView?
    ) -> TerminalController {
        if let placement,
           let controller = TerminalController.newTab(
               ghostty,
               from: placement.window,
               withSurfaceTree: tree,
               ordered: placement.ordered,
               select: select,
               initialFocus: initialFocus) {
            return controller
        }

        // The size of the terminal that started the session: the panes'
        // views are new, so the tree has no size of its own to offer.
        return TerminalController.newWindow(
            ghostty,
            tree: tree,
            position: position,
            contentSize: hostSize,
            initialFocus: initialFocus)
    }

    /// Where a new tab for `windows[index]` goes: after or before a window
    /// of this host already on screen, or nil if it has nothing on screen
    /// yet.
    ///
    /// Asked rather than remembered, because a remembered one goes stale:
    /// the tmux window holding it can close while others stay open, and
    /// the next window to arrive would then have nothing to join and
    /// would come up on its own.
    ///
    /// Found by walking tmux's order rather than by taking any window of
    /// this host. Any of them finds the right tab group, but `newTab`
    /// puts the tab next to *the one it is given*, and `windows` is a
    /// dictionary -- so picking whichever came out first dropped new tabs
    /// at an arbitrary position in the bar.
    private func tabParent(
        _ windows: [Ghostty.Action.TmuxWindows.Window],
        of index: Int,
        host: ObjectIdentifier
    ) -> (window: NSWindow, ordered: NSWindow.OrderingMode)? {
        // After the nearest window before this one that is on screen.
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return (window, .above) }
        }

        // Nothing before it on screen -- tmux's current window is built
        // first, and may come later in tmux's order -- so before the
        // nearest one after it.
        for i in stride(from: index + 1, to: windows.count, by: 1) {
            if let window = liveWindow(id: windows[i].id, host: host) { return (window, .below) }
        }

        return nil
    }

    /// The window showing a tmux window, if it is still in a tab group or
    /// on screen. A tab that was never selected is not visible, but it is
    /// in the tab bar and something can go next to it.
    private func liveWindow(id: Int, host: ObjectIdentifier) -> NSWindow? {
        guard let window = windows[Key(host: host, id: id)]?.controller?.window,
              window.isVisible || window.tabGroup?.windows.contains(window) == true
        else { return nil }
        return window
    }

    /// Show the tmux window's name as the window title, marked with its
    /// alerts the way tmux's status line marks them.
    ///
    /// tmux owns what a tmux window is called, so this goes in as the
    /// override: the surface titles underneath are the panes' own titles,
    /// which is a different thing. Assigning only on a change keeps this
    /// off the main thread's work list for the common case where tmux
    /// re-reports a layout that did not move.
    ///
    /// The marks are tmux's, not ours to clear: tmux sets them only on a
    /// window it is not on and clears them when it moves there, and
    /// selecting the tab is what moves it. A bell is not marked again when
    /// the pane that rang it already shows one: that bell reached the
    /// surface as well (the bell feature `title`), and both would say the
    /// same thing.
    private func setTitle(
        _ controller: TerminalController,
        _ window: Ghostty.Action.TmuxWindows.Window
    ) {
        var marks: [String] = []
        if window.alerts.bell && !(controller.focusedSurface?.bell ?? false) {
            marks.append("🔔")
        }
        if window.alerts.activity { marks.append("•") }
        if window.alerts.silence { marks.append("💤") }

        let name = ([marks.joined()] + [window.name])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
