const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");
const sinkpkg = @import("sink.zig");
const passthrough = @import("passthrough.zig");
const Sink = sinkpkg.Sink;

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │            startup_block                    │
///                              │                                             │
///                              │  Wait for initial %begin/%end block from    │
///                              │  tmux. This is the response to the initial  │
///                              │  command (e.g., "attach -t 0").             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %end / %error
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           startup_session                   │
///                              │                                             │
///                              │  Wait for %session-changed notification     │
///                              │  to get the initial session ID.             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %session-changed
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                │  For each new pane
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │     pane_history                            │
///                              │  Scrollback, always the primary screen's.   │
///                              └─────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │     pane_saved (capture-pane -a)            │
///                              │  The primary grid tmux put aside while the  │
///                              │  pane is in the alternate screen. Failing   │
///                              │  means the pane is on its primary screen.   │
///                              └─────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │     pane_visible                            │
///                              │  The grid on display, into whichever screen │
///                              │  pane_saved said that is.                   │
///                              └─────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// I/O implementation used for all internal state.
    io: std.Io,

    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The current session's name, as tmux last reported it. Owned, and
    /// empty only until the first `%session-changed`: tmux refuses an
    /// empty session name.
    session_name: []const u8 = "",

    /// See `Options.reattach_command`. Owned, or empty.
    reattach_command: []const u8 = "",

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// The tmux server's host name, from `#{host}` alongside the version.
    /// Owned; empty until then. A pane's working directory is a path on
    /// this host, and only means something here if this host is ours:
    /// see `sinkpkg.Op.pwd`.
    server_host: []const u8 = "",

    /// The tmux server's home directory, from `#{HOME}` alongside the
    /// version. Owned; empty until then, and on a server that cannot say.
    /// See `paneTitle`.
    server_home: []const u8 = "",

    /// The last client size we reported to tmux, so we don't re-send an
    /// unchanged one. See `nextClientSize`.
    last_client_size: ?struct {
        cols: usize,
        rows: usize,
    } = null,

    /// The commands waiting for tmux's reply, oldest first.
    ///
    /// Commands are pipelined: each is sent as soon as it is queued
    /// rather than when the one ahead of it is answered. tmux runs a
    /// control client's commands one at a time in the order it reads
    /// them, and answers each with its own `%begin`/`%end` block in that
    /// same order, so the oldest command here is always the one the next
    /// block answers. Waiting for each reply before sending the next
    /// bought nothing for that, and cost a round trip per command: a
    /// keystroke typed while a pane's history was being captured waited
    /// for the whole capture to cross the wire before it was even sent.
    command_queue: CommandQueue,

    /// How many commands at the front of `command_queue` have been sent.
    /// Everything after them is sent by the next `flushCommands`, which
    /// every path that queues a command runs before returning.
    commands_sent: usize = 0,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// Seconds of backlog tmux may hold for us before pausing a pane, or
    /// 0 for tmux's own behaviour. See `Options.pause_after`.
    pause_after: u32 = 0,

    /// How many lines of a pane's history to read, or null for all of
    /// them. See `Options.history_limit`.
    history_limit: ?u32 = null,

    /// See `Options.history_chunk`.
    history_chunk: ?u32 = null,

    /// Whether tmux's paste buffers are passed on as they change. See
    /// `Options.mirror_paste_buffers`.
    mirror_paste_buffers: bool = false,

    /// Client flags asked for on attach. See `Options.client_flags`.
    client_flags: ClientFlags = .{},

    /// Every session on the server, ours included, as of the last
    /// `list-sessions`. Owned, names and all.
    ///
    /// Empty until something asks for it with `.list_sessions`: a GUI
    /// that never shows other sessions should not pay a round trip on
    /// attach and another on every session coming and going. Once asked
    /// for, it is kept current: see `sessions_wanted`.
    sessions: std.ArrayList(Session) = .empty,

    /// Whether anything has asked for `sessions`. From then on it is
    /// listed again whenever tmux says the set of sessions changed.
    ///
    /// tmux has no notification for a window opening or closing in a
    /// session other than ours, so their window counts can go stale in
    /// between. Asking again with `.list_sessions` refreshes them.
    sessions_wanted: bool = false,

    /// See `Options.follow_window_order`.
    follow_window_order: bool = false,

    /// See `Options.attach_layout`.
    attach_layout: AttachLayout = .tmux,

    /// Whether the session's windows have been listed yet. Those listed
    /// first are the ones attaching found, which `attach_layout` lays out;
    /// any that open later are left as they come.
    windows_listed: bool = false,

    /// Whether the layouts saved in the session's windows have been read,
    /// or need not be. See `Window.arrange_pending`.
    saved_layouts_known: bool = true,

    /// See `Options.status_line`.
    status_line: bool = false,

    /// What tmux's status line says, as of its last change. Each part is
    /// owned, and empty until tmux first says. Carried over a session
    /// change: tmux only tells us when one changes, and one that did not
    /// change across the switch would otherwise be lost.
    status: Status = .{},

    /// See `Options.lazy_history`.
    lazy_history: bool = false,

    /// Whether tmux has made this client read-only, by `attach -r` or
    /// `switch-client -r`. See `refuseReadOnly`.
    ///
    /// Asked alongside the version on attach, and again on every session
    /// change, which is how `switch-client -r` shows: tmux announces the
    /// change as a `%session-changed` for the session we are already on.
    /// (`list-windows` cannot say: its formats have no client.)
    read_only: bool = false,

    /// When we last told the user that typing goes nowhere because the
    /// client is read-only, so that every keystroke does not say it again.
    read_only_noticed: ?std.Io.Timestamp = null,

    /// A change of `read_only` the user has not been told about yet. Held
    /// until the window list that always follows has gone out, so that a
    /// GUI showing it over the pane the user is in finds that pane: a
    /// session change empties the window list first.
    read_only_untold: bool = false,

    /// The tmux paste buffer our pastes go through. See `nextPaste`.
    ///
    /// Random per viewer because buffers belong to the server, not to us:
    /// another client of the same server, another ghostty among them,
    /// can run its commands in between ours, and a name we shared with
    /// it would let two pastes mix.
    paste_buffer: [paste_buffer_prefix.len + 16]u8,

    /// Seconds a pane has to be out of sight, and still producing output,
    /// before we ask tmux to stop sending it. 0 never does. See
    /// `Options.hidden_output_off_after`.
    hidden_output_off_after: u32 = 0,

    /// Whether we have subscribed to this session's alerts, titles and
    /// working directories. See `syncLayouts`.
    subscribed: bool = false,

    /// Titles and working directories tmux reported for panes we had not
    /// listed yet, by pane id, applied once the layout bringing the pane
    /// arrives. See `paneName`.
    ///
    /// tmux sends a subscription's value once and then only on a change,
    /// and a pane in a new window is reported by the next check whether
    /// or not our `list-windows` for that window has been answered. Owned.
    pending_names: std.AutoHashMapUnmanaged(usize, PendingNames) = .empty,

    /// Where a query of the windows' alert flags stands, on a server too
    /// old to tell us about them by subscription. See `requestAlerts`.
    alerts_query: enum {
        /// Nothing asked.
        idle,
        /// Asked, and nothing has happened since that it may have missed.
        sent,
        /// Asked, and there has been output since, so ask again once
        /// this one is answered.
        stale,
    } = .idle,
    /// What tmux prints to say a command line the user typed is done.
    /// See `nextCommandLine`. Random per viewer, like `paste_buffer`, so
    /// that nothing a command prints can be taken for it.
    command_marker: [command_marker_prefix.len + 16]u8,

    /// The window tmux is on once the selects we have sent have run:
    /// what tmux last said, moved by each `select-window` of ours as it
    /// is sent. Null until tmux tells us. See `sessionWindowChanged`.
    current_window_id: ?usize = null,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    /// The pre-allocated actions for a session ending with a reason: the
    /// notice carrying it, then the exit. Pre-allocated for the same
    /// reason as `action_single`.
    action_exit: [2]Action,

    /// The pre-allocated actions for giving up on a session we can no
    /// longer follow: see `abandon`.
    action_abandon: [3]Action,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, *Pane);

    const paste_buffer_prefix = "ghostty-paste-";
    const command_marker_prefix = "ghostty-done-";

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// tmux has something to say that a person should see. See
        /// `Notice`.
        notice: Notice,

        /// tmux's status line changed. See `Options.status_line`.
        status: Status,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        ///
        /// The session list, `Viewer.sessions`, is part of what this
        /// announces: a change to it is sent as one of these too.
        windows: []const Window,

        /// One of tmux's paste buffers changed, and this is what it now
        /// holds, for the system clipboard. Only with
        /// `Options.mirror_paste_buffers`. The bytes are the buffer's,
        /// exactly: not NUL terminated, not necessarily UTF-8, never
        /// empty.
        paste_buffer: []const u8,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        // What the user copied is nobody's business,
                        // least of all the log's.
                        if (comptime std.mem.eql(u8, u_field.name, "paste_buffer")) {
                            try writer.print("[{d} bytes]", .{value.len});
                        } else switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            // Window embeds ArenaAllocator.State; dumping
                            // `{any}` walks freed/poisoned arena nodes.
                            []const Window => try writer.print("[{d} windows]", .{value.len}),
                            Notice => try writer.print(
                                "{t} \"{s}\"",
                                .{ value.kind, value.text },
                            ),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    /// Text from tmux meant for the user rather than for us.
    ///
    /// A normal tmux client shows these on its status line or in a pane;
    /// a control client is only told about them, so unless whatever is
    /// driving the viewer shows them, they are lost. They are all free
    /// text written by tmux (or by whoever ran `display-message`) and are
    /// not localized or structured beyond `kind`.
    pub const Notice = struct {
        kind: Kind,

        /// Not NUL terminated, and never empty. Like everything in an
        /// action, valid only until the next call to `next`.
        text: []const u8,

        /// Sync with: ghostty_tmux_notice_kind_e
        pub const Kind = enum(c_int) {
            /// `display-message` run against this client, which tmux
            /// would show on the status line. Informational.
            message,

            /// An error from loading the tmux configuration. tmux
            /// reports these to the first client that attaches after the
            /// server started.
            config_error,

            /// A command sent on the user's behalf failed, such as a
            /// split tmux has no room for. The text is tmux's error.
            command_error,

            /// The session ended, and this is tmux's reason (for example
            /// "detached", "server exited" or "too far behind"). Always
            /// immediately followed by the `exit` action.
            exit,

            /// What a command line the user typed printed, such as the
            /// list `list-sessions` answers with. May be several lines.
            /// Its errors come as `command_error`.
            command_output,

            /// The tmux server is older than the oldest we support, so
            /// we have left the session rather than half show it. The
            /// text names the version found and the one needed. Always
            /// immediately followed by a `detach-client` command and the
            /// `exit` action; the session keeps running in tmux.
            unsupported,

            /// The connection to tmux dropped without the session ending:
            /// control mode stopped with no `%exit` from tmux, so the
            /// session is most likely still running. The text is the
            /// command line that started control mode in the host
            /// terminal, which running again there reattaches. Only sent
            /// when that command is known (see `Options.reattach_command`);
            /// otherwise the drop is reported as an `exit` notice. Always
            /// immediately followed by the `exit` action.
            connection_lost,
        };
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,

        /// Data to write to a pane, e.g. keyboard input encoded by the
        /// caller into the bytes a normal pty would receive.
        write: Write,

        /// Text to paste into a pane, already through the caller's paste
        /// encoding but without a bracketed paste frame: tmux adds that
        /// itself if the pane's program asked for it. See `nextPaste`.
        paste: Write,

        /// Ask tmux to resize a pane, because whatever is displaying it
        /// changed size.
        resize: Resize,

        /// Tell tmux how big our control mode client is. tmux sizes the
        /// session to its smallest attached client, so without this a
        /// second attached client can pin our panes small.
        client_size: ClientSize,

        /// Ask tmux for a new window in this session, because the GUI
        /// asked for a new tab.
        new_window: NewWindow,

        /// Leave the session, because the user asked to detach.
        detach: void,

        /// Tell tmux the user moved into this pane.
        select_pane: SelectPane,

        /// Toggle whether this pane is zoomed, because the GUI asked.
        zoom_pane: ZoomPane,

        /// Move this pane's window along the session's window order.
        move_window: MoveWindow,

        /// Rename the window this pane is in.
        rename_window: RenameWindow,

        /// Ask tmux to split a pane, because the GUI asked for a split.
        split: Split,

        /// Ask tmux to close windows, because the GUI closed a tab.
        kill_windows: KillWindows,

        /// Ask tmux to kill a pane, because the thing displaying it was
        /// closed.
        kill_pane: KillPane,

        /// Whatever displays this pane came into sight or went out of it:
        /// its tab was selected or left, its window minimized or covered.
        pane_shown: PaneShown,

        /// Whatever displays this pane wants history older than it has:
        /// it was scrolled near the top of its scrollback, or is about
        /// to search it. Only means anything with
        /// `Options.history_chunk`; without it there is nothing older to
        /// read. See `nextHistoryWanted`.
        history_wanted: HistoryWanted,

        /// Whatever displays this pane needs all of its history, as far
        /// as `Options.history_limit` goes, before it can do what it was
        /// asked: select all of it, or write it to a file. The pane is
        /// read from scratch, history and all, and once that is applied
        /// the display is sent `.history_complete`. Always answered,
        /// whether or not the history is read on demand.
        read_history: PaneId,

        /// Whatever displays this pane refused older history because its
        /// line where the two overlap was not the display's: our
        /// scrollback and tmux's history no longer agree line for line.
        /// The pane is read again from scratch, as for a resize. See
        /// `nextHistoryDrifted`.
        history_drifted: HistoryDrifted,

        /// Trade places with another pane of the same window.
        swap_pane: SwapPane,

        /// Move every pane of a window one place along.
        rotate_window: RotateWindow,

        /// Take a pane out of its window into a new window of its own.
        break_pane: BreakPane,

        /// Move a pane into the window before or after its own.
        join_pane: JoinPane,

        /// Move a pane beside another one, in its own window or another,
        /// because the GUI dragged one split onto another.
        move_pane: MovePane,

        /// A command line the user typed for tmux to run, as at tmux's
        /// own command prompt. See `nextCommandLine`.
        command_line: CommandLine,

        /// Control mode ended without tmux saying so: the stream carrying
        /// it stopped with no `%exit` before it. tmux says `%exit`
        /// whenever one of its clients leaves, however it leaves, so this
        /// is the connection to tmux breaking (ssh losing the network,
        /// typically) and not the session ending. Ends the viewer like
        /// an exit does.
        connection_lost: void,

        /// Hide a window from the GUI, or show it again. See
        /// `Window.hidden`.
        hide_window: HideWindow,

        /// Move this client to another session on the same server.
        switch_session: SwitchSession,

        /// Read the server's sessions into `sessions`, and keep them
        /// current from now on. See `sessions_wanted`.
        list_sessions: void,

        pub const Write = struct {
            pane_id: usize,
            data: []const u8,
        };

        pub const Resize = struct {
            pane_id: usize,
            cols: usize,
            rows: usize,
        };

        pub const ClientSize = struct {
            cols: usize,
            rows: usize,
        };

        /// Which way a new pane goes relative to the one being split.
        /// tmux only has two axes; the apprt resolves "auto" before it
        /// gets here.
        pub const Split = struct {
            pane_id: usize,
            direction: Direction,

            /// Start the new pane in the working directory of the one
            /// being split, as a split does in plain Ghostty. See
            /// `startDirectory`.
            inherit_working_directory: bool = false,

            pub const Direction = sinkpkg.SplitDirection;
        };

        pub const NewWindow = struct {
            /// The pane the user asked from, if any. The new window goes
            /// right after this pane's window, as a new tab does in plain
            /// Ghostty.
            pane_id: ?usize = null,

            /// Whether the new window starts in `pane_id`'s working
            /// directory rather than tmux's default. See `startDirectory`.
            inherit_working_directory: bool = false,
        };

        pub const KillWindows = struct {
            /// A pane in the window the user acted on. The window is
            /// found from this rather than passed directly, because a
            /// surface knows which pane it is and nothing else.
            pane_id: usize,
            scope: Scope,

            pub const Scope = sinkpkg.KillScope;
        };

        pub const SelectPane = struct {
            pane_id: usize,
        };

        pub const ZoomPane = struct {
            pane_id: usize,
        };

        pub const RenameWindow = struct {
            /// A pane in the window being renamed.
            pane_id: usize,

            /// The name the user typed. Empty means "go back to naming
            /// itself"; see `nextRenameWindow`.
            name: []const u8,
        };

        pub const MoveWindow = struct {
            /// A pane in the window being moved. The surface knows which
            /// pane it is and nothing else.
            pane_id: usize,

            /// How far to move, in windows, signed. Relative because
            /// that is what the GUI verb is: "one to the left".
            amount: isize,
        };

        pub const KillPane = struct {
            pane_id: usize,
        };

        pub const PaneShown = struct {
            pane_id: usize,
            shown: bool,
        };

        pub const PaneId = struct {
            pane_id: usize,
        };

        pub const HistoryDrifted = struct {
            pane_id: usize,

            /// The `read` of the refused `sinkpkg.Op.OlderHistory`.
            read: u32,
        };

        pub const HistoryWanted = struct {
            pane_id: usize,

            /// How many rows of scrollback the display holds above its
            /// screen. The older history is read from the line above
            /// the oldest of them.
            held: usize,

            /// All of what is left, up to `Options.history_limit`, rather
            /// than the next chunk: for a search through all of it.
            all: bool = false,
        };

        pub const SwapPane = struct {
            pane_id: usize,
            target: Target,

            pub const Target = sinkpkg.SwapTarget;
        };

        pub const RotateWindow = struct {
            /// A pane in the window to rotate.
            pane_id: usize,

            /// `next` moves each pane into the place of the one after it,
            /// as `rotate-window -D`; `previous` the other way, as `-U`.
            direction: sinkpkg.Adjacent,
        };

        pub const BreakPane = struct {
            pane_id: usize,
        };

        pub const JoinPane = struct {
            pane_id: usize,

            /// Which window, of the ones either side of the pane's own in
            /// tmux's order.
            window: sinkpkg.Adjacent,
        };

        pub const MovePane = struct {
            pane_id: usize,

            /// The pane it goes beside.
            target_pane_id: usize,

            /// Which side of the target it goes on.
            direction: Split.Direction,
        };

        pub const CommandLine = struct {
            /// Borrowed for the duration of the call.
            text: []const u8,
        };

        pub const HideWindow = struct {
            /// The tmux window, by id rather than by a pane in it: a
            /// hidden window has no surface to ask from.
            window_id: usize,
            hidden: bool,
        };

        pub const SwitchSession = struct {
            session_id: usize,
        };
    };

    /// A session on the server we are attached to, ours or another.
    pub const Session = struct {
        id: usize,

        /// Owned by the viewer's allocator.
        name: []const u8,

        /// How many windows it has.
        windows: usize,

        /// How many clients are attached to it, us included if it is
        /// the one we are on.
        attached: usize,
    };

    /// Flags for this client that change how tmux treats it, set with
    /// `refresh-client -f` on attach. Each is off unless asked for.
    pub const ClientFlags = packed struct {
        /// The client has an active pane of its own, so moving between
        /// panes here does not move the active pane every other client
        /// sees. tmux still moves the window's shared active pane for a
        /// split or a pane closing, and we follow that. See
        /// `nextSelectPane`.
        active_pane: bool = false,

        /// When the session we are on is destroyed, tmux moves us to
        /// another session if there is one rather than ending control
        /// mode. It arrives as an ordinary session change.
        no_detach_on_destroy: bool = false,

        pub fn any(self: ClientFlags) bool {
            return self.active_pane or self.no_detach_on_destroy;
        }
    };

    /// How the splits of a window found on attach are laid out.
    ///
    /// tmux spreads a change in a window's size over its panes by its own
    /// rules, which do not keep their proportions, so a window another
    /// client of a different size has had comes back here uneven.
    pub const AttachLayout = enum {
        /// As tmux has it.
        tmux,

        /// As we last had it, in proportion, when the panes are still
        /// the same panes split the same way; otherwise equally.
        restore,

        /// Equally, as `equalize_splits` does.
        equalize,
    };

    pub const Window = struct {
        id: usize,

        /// The window's tmux name, owned by the viewer's allocator.
        ///
        /// Deliberately *not* in `layout_arena`: whatever a GUI shows for
        /// this window -- a tab label, a title bar -- is this, and it
        /// crosses the C ABI as a pointer the GUI reads later, so it has
        /// to outlive the layout it arrived with. The arena is reset
        /// wholesale on every layout change, which a name living in it
        /// does not survive.
        ///
        /// Updated in place by `%window-renamed` rather than costing a
        /// round trip to `list-windows`.
        name: []const u8,

        /// The pane filling this window because it is zoomed, if one is.
        ///
        /// Only ever read from tmux, never set here: zoom is a fact about
        /// the tmux window, and a GUI that toggled it locally would
        /// disagree with the session until the next layout arrived.
        zoomed_pane_id: ?usize = null,

        /// The window's active pane, as tmux has it: where its cursor is
        /// and where input without a target goes. Every window has one,
        /// so this is only null for a window built before we were told.
        ///
        /// Like `zoomed_pane_id` this is only ever read from tmux, from
        /// `list-windows` and then `%window-pane-changed`, which tmux
        /// sends whatever moved it: this client, another one, a script,
        /// or a pane closing. A GUI showing the window should keep its
        /// focus on this pane.
        active_pane_id: ?usize = null,

        /// Whether tmux is currently on this window. Kept on the window
        /// rather than as one id on the viewer because that is the shape
        /// the GUI reads it in, and it cannot then disagree with the set
        /// it arrived with.
        active: bool = false,

        /// What tmux would flag this window with in its status line.
        /// Like `active`, only ever read from tmux.
        alerts: Alerts = .{},

        /// Whether the user has hidden this window from the GUI. It is
        /// still in the session and still running; it just has no tab.
        ///
        /// Kept in tmux, as a user option on the window
        /// (`@ghostty-hidden`), rather than here: it then survives
        /// detaching and attaching again, from this machine or another,
        /// the way the user would expect of something they set on a
        /// window. tmux sends no notification when an option changes,
        /// so another client hiding a window shows here the next time
        /// the window list is read.
        ///
        /// Nothing is read for a hidden window's panes, and nothing is
        /// mirrored to anything displaying them: `attachPane` is for
        /// panes that are shown. Showing the window again reads its panes
        /// from scratch, as on attach. See `syncHidden`.
        hidden: bool = false,

        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,

        /// What tmux shows of the window while a pane is zoomed: the
        /// zoomed pane alone, at the size of the whole window. Null
        /// while nothing is zoomed. In `layout_arena`.
        ///
        /// A zoomed window's `layout` is still the unzoomed one, which
        /// tmux keeps to go back to, and the other panes really are
        /// still the size it says: tmux leaves them alone. The zoomed
        /// pane is not. tmux resizes it to fill the window and writes
        /// its output for that size, so its size comes from here, and
        /// so does the window's when the GUI asks for one: the zoomed
        /// pane's surface is then the only one on screen. See
        /// `shownLayout`.
        zoomed_layout: ?Layout = null,

        /// The last size we asked tmux to make this window. Like a pane's
        /// request this is what we asked for, not what tmux settled on, so
        /// that a clamped request is not re-sent forever. See
        /// `windowResizeCommand`.
        last_size_request: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        /// Whether tmux last laid this window out at a size other than
        /// `last_size_request`: another client attached to the session
        /// took the window over. See `reclaimWindowSize`.
        size_taken: bool = false,

        /// Whether this window, found on attach, is still to be laid out
        /// as `Viewer.attach_layout` says. That happens once, when we
        /// first size it: the layout is then made for the size we asked
        /// for, in the same breath, so tmux has no chance to spread the
        /// change of size its own way. See `arrangeCommand`.
        arrange_pending: bool = false,

        /// The layout we last saw this window at our size, as saved in
        /// the window (`@ghostty-layout`), the last time it was read.
        /// Only until it is restored. Owned.
        ///
        /// A user option on the window, like `@ghostty-hidden`, so it is
        /// there for the next attach, from this machine or another.
        /// Saved as the layout changes while we size the window, and not
        /// while another client does: the layout another client has
        /// squeezed or stretched is not the one the user left here.
        saved_layout: ?[]const u8 = null,

        /// A hash of the layout we last saved, so the same one is not
        /// saved again.
        saved_hash: ?u64 = null,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            alloc.free(self.name);
            if (self.saved_layout) |v| alloc.free(v);
            self.layout_arena.promote(alloc).deinit();
        }

        /// The layout on screen: the zoomed pane alone while one is,
        /// otherwise the whole of it. This is what the window's size is
        /// composed from, and what the panes on display ask to be sized
        /// within.
        pub fn shownLayout(self: *const Window) Layout {
            return self.zoomed_layout orelse self.layout;
        }

        /// Whether we have asked tmux for a size it has not laid this
        /// window out at yet. Until it does, the layout we have is the
        /// one the request replaces, so what panes add up to in it is
        /// not the window's size. A layout at another size is tmux's
        /// answer all the same (see `size_taken`), and ends the wait.
        fn sizePending(self: *const Window) bool {
            const want = self.last_size_request orelse return false;
            if (self.size_taken) return false;
            const shown = self.shownLayout();
            return shown.width != want.cols or shown.height != want.rows;
        }
    };

    /// The alerts tmux keeps per window and shows in its status line:
    /// `#{window_bell_flag}`, `#{window_activity_flag}` and
    /// `#{window_silence_flag}`.
    ///
    /// tmux decides all of these, by its `monitor-bell`,
    /// `monitor-activity` and `monitor-silence` options, and sets them
    /// only on a window the session is not on. It clears them when the
    /// session moves to the window, which is the one change we can see
    /// for ourselves (`%session-window-changed`); everything else comes
    /// from tmux, by subscription where it can.
    pub const Alerts = struct {
        bell: bool = false,
        activity: bool = false,
        silence: bool = false,

        /// The subscription's value: one `0` or `1` per flag, in field
        /// order. See `Command.subscribe`.
        pub fn parse(value: []const u8) ?Alerts {
            const v = std.mem.trim(u8, value, " \t\r\n");
            if (v.len != 3) return null;
            for (v) |c| if (c != '0' and c != '1') return null;
            return .{
                .bell = v[0] == '1',
                .activity = v[1] == '1',
                .silence = v[2] == '1',
            };
        }

        pub fn eql(a: Alerts, b: Alerts) bool {
            return a.bell == b.bell and
                a.activity == b.activity and
                a.silence == b.silence;
        }
    };

    /// A single tmux pane.
    ///
    /// Panes are heap allocated and referenced by pointer from `PanesMap`,
    /// so that a pane keeps one address for its whole life. That matters
    /// because `stream` contains pointers back into the pane: the parser's
    /// handler points at `terminal`, and the OSC parser's capture writer
    /// points into the parser's own buffer. A pane stored by value in a
    /// hash map would have all of those silently invalidated the first
    /// time the map grew or the pane was moved between maps, and a
    /// half-parsed OSC sequence would then write through a dangling
    /// pointer.
    pub const Pane = struct {
        terminal: Terminal,

        /// The VT parser for this pane.
        ///
        /// This is persistent because tmux splits a pane's output across
        /// `%output` notifications wherever the pty write landed, so an
        /// escape sequence can straddle two of them. A fresh parser per
        /// notification loses the prefix and prints the tail as text.
        stream: TerminalStream,

        /// Takes tmux's passthrough escape back out of the pane's
        /// output, ahead of `stream`. Persistent for the same reason.
        passthrough: passthrough.Unwrapper,

        /// Where this pane's operations are mirrored, if anything has
        /// attached. See `attachPane`.
        sink: ?Sink = null,

        /// The size this pane is asking for and has not been given.
        ///
        /// Used by `composeLayoutSize` to work out how big the window has
        /// to be. Cleared as soon as tmux answers with a layout, because
        /// from then on tmux's size is the truth about this pane and a
        /// spent request would compose a stale window for a sibling.
        last_resize_request: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        /// The last size we actually asked tmux for.
        ///
        /// Deliberately separate from `last_resize_request`, and
        /// deliberately never cleared by tmux: a resize is a request and
        /// the layout is the ruling, so tmux is free to answer with
        /// something else. When it does, the surface has not moved and
        /// asks for the same size again -- and because every resize is
        /// answered with a layout, re-sending it is not one wasted round
        /// trip but a loop with no end. This remembers the question we
        /// already had answered so we do not ask it again.
        last_resize_sent: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        /// The size this pane had before the last tmux layout resized
        /// it, held until the pane's surface reports under the new
        /// layout.
        ///
        /// Panes are relaid out together but report one at a time, and
        /// a report takes a moment to travel: a surface can compute its
        /// size from the layout tmux just replaced and have that report
        /// arrive *after* the new layout was applied. Recording it
        /// would let it complete a sibling's fresh set, and the batch
        /// composed from the pair asks tmux for a window neither layout
        /// describes -- tmux answers, the layout changes again, and the
        /// two surfaces chase each other's stale reports forever.
        ///
        /// A report of exactly this size while it is set is that stale
        /// echo, and is dropped. Any other size is from the new layout
        /// (per surface, reports are ordered: everything computed from
        /// the old tree arrives before the first report computed from
        /// the new one), so it clears this. See `nextResize`.
        stale_size: ?struct {
            cols: usize,
            rows: usize,
        } = null,

        /// Which of our screens tmux's visible grid is, as learned from
        /// the saved-grid capture that precedes each visible capture.
        ///
        /// tmux keeps one grid per pane on display and, while the pane
        /// is in the alternate screen, a copy of the primary one put
        /// aside (`saved_grid`). A plain `capture-pane` reads the grid
        /// on display, whichever screen that is, and `-a` reads the one
        /// put aside, failing when there is none. So the saved-grid
        /// reply tells us whether the visible reply after it belongs to
        /// the alternate screen or the primary. See `paneCaptures`.
        visible_screen: ScreenSet.Key = .primary,

        /// Since when nothing has been showing this pane, or null while
        /// something is. See `Input.pane_shown`.
        hidden_since: ?std.Io.Timestamp = null,

        /// Whether we have asked tmux to stop sending this pane's output.
        /// See `Options.hidden_output_off_after`.
        output_off: bool = false,

        /// The history and saved grid of the read in flight, decoded and
        /// held until the grid on display arrives, so that the whole
        /// read is applied at once. Owned.
        ///
        /// A read replaces the pane's content wholesale, scrollback and
        /// all. Applied reply by reply, a pane read again while it is on
        /// screen -- for its history after a lazy attach, or after a
        /// pause -- would show an empty screen in between, for as long
        /// as a large history took to arrive.
        ///
        /// `read_history` is only set for a full read, one that started
        /// with the history; an empty slice is a history tmux could not
        /// give us. See `paneCaptures`.
        read_history: ?[]u8 = null,
        read_saved: ?[]u8 = null,

        /// Full reads queued for this pane and not yet applied. While
        /// there are any, the pane's history is not all here yet.
        full_reads: u32 = 0,

        /// Whether tmux paused this pane and the read that recovers it
        /// has not been applied yet. See `Viewer.pauseRecover`.
        paused: bool = false,

        /// The status last sent to the sink. See `Viewer.updatePaneStatus`.
        status: sinkpkg.PaneStatus = .live,

        /// tmux resized this pane, and what is on display has to be read
        /// again. See `syncLayouts`.
        reread: bool = false,

        /// The pane's working directory as tmux last reported it,
        /// `#{pane_current_path}`: a path on the server's host. Owned;
        /// empty until tmux has said.
        ///
        /// Kept apart from the terminal's pwd, which is what the display
        /// is told. The pane's program writes that one too, with its
        /// own OSC 7, as a URL; a new pane started where this one is
        /// needs the plain path tmux understands. See `startDirectory`.
        path: []const u8 = "",

        /// The pane's foreground command and title as tmux last reported
        /// them, `#{pane_current_command}` and `#{pane_title}`. Owned;
        /// empty until tmux has said, which `named` tells apart from tmux
        /// saying nothing. What the pane is titled with is made from
        /// these: see `Viewer.paneTitle`.
        command: []const u8 = "",
        tmux_title: []const u8 = "",
        named: bool = false,

        /// Whether `tmux_title` was set by the program running now, as
        /// opposed to one that has since exited, or tmux's default.
        title_current: bool = false,

        /// Whether a read of older history is in flight for this pane.
        /// One at a time: the next one starts where this one ends, which
        /// only the display knows once it has this one. See
        /// `Viewer.nextHistoryWanted`.
        older_reading: bool = false,

        /// What the display asked for while a read of older history was
        /// in flight, to be read once it has landed. The newest ask wins.
        older_wanted: ?Input.HistoryWanted = null,

        /// How many reads from scratch, the ones that replace the
        /// pane's history, have been applied. A read of older history
        /// is measured against the history the last of them left, and
        /// carries this to say which. See `Input.history_drifted`.
        history_reads: u32 = 0,

        /// Whether a read from scratch was queued because the display's
        /// history drifted from tmux's, and has not been applied yet.
        drift_reread: bool = false,

        /// The read from scratch that a drift re-read turned out to be,
        /// once applied. Drifting again against that one means reading
        /// again will not help.
        drift_read: ?u32 = null,

        /// Older history has stopped being read for this pane, because
        /// it drifted even right after a re-read. Until the next read
        /// from scratch for some other reason (a resize, a pause).
        older_off: bool = false,

        /// Whether the read whose history is held in `read_history` is
        /// one the display asked for all of (`Input.read_history`), to
        /// be told when it is in.
        read_all: bool = false,

        pub fn create(
            io: std.Io,
            alloc: Allocator,
            cols: size.CellCountInt,
            rows: size.CellCountInt,
        ) !*Pane {
            const self = try alloc.create(Pane);
            errdefer alloc.destroy(self);

            self.terminal = try .init(io, alloc, .{
                .cols = cols,
                .rows = rows,

                // Characters as wide as tmux makes them, as in the
                // surface showing the pane. See the termio stream
                // handler's `follow_grapheme_mode`.
                .default_modes = .{ .grapheme_cluster = true },
            });
            errdefer self.terminal.deinit(alloc);

            // Only valid because `self` never moves again.
            self.stream = self.terminal.vtStream();
            self.passthrough = .{};
            self.sink = null;

            // Field defaults do not apply here: `self` is uninitialized
            // memory and every field is assigned by hand, so anything left
            // out keeps whatever was in the allocation.
            self.last_resize_request = null;
            self.last_resize_sent = null;
            self.stale_size = null;
            self.visible_screen = .primary;
            self.hidden_since = null;
            self.output_off = false;
            self.read_history = null;
            self.read_saved = null;
            self.full_reads = 0;
            self.paused = false;
            self.status = .live;
            self.reread = false;
            self.path = "";
            self.command = "";
            self.tmux_title = "";
            self.named = false;
            self.title_current = false;
            self.older_reading = false;
            self.older_wanted = null;
            self.history_reads = 0;
            self.drift_reread = false;
            self.drift_read = null;
            self.older_off = false;
            self.read_all = false;

            return self;
        }

        pub fn destroy(self: *Pane, alloc: Allocator) void {
            if (self.sink) |s| s.close();
            if (self.path.len > 0) alloc.free(self.path);
            if (self.command.len > 0) alloc.free(self.command);
            if (self.tmux_title.len > 0) alloc.free(self.tmux_title);
            if (self.read_history) |v| alloc.free(v);
            if (self.read_saved) |v| alloc.free(v);
            self.stream.deinit();
            self.terminal.deinit(alloc);
            alloc.destroy(self);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub const Options = struct {
        /// Seconds of pane output tmux may buffer for us before it pauses
        /// the pane and tells us, or 0 to leave the flag unset.
        ///
        /// Unset is tmux's default and it is not a safe one: a control
        /// client that falls behind is not throttled, and once the
        /// backlog passes `CONTROL_MAXIMUM_AGE` (five minutes) tmux kills
        /// the client, taking every window of the session with it.
        ///
        /// The reason this is not simply always on is that a paused pane
        /// has its output *discarded* rather than buffered, so resuming
        /// means re-reading the pane and losing whatever scrolled past.
        /// Which of the two is worse belongs to the user.
        pause_after: u32 = 0,

        /// Seconds a pane may be out of sight (`Input.pane_shown`) while
        /// still producing output before we turn its output off with
        /// `refresh-client -A '%id:off'`, or 0 never to.
        ///
        /// This saves sending, and parsing, output nobody is looking at.
        /// The catch is tmux's: a pane every attached client has turned
        /// off is not read at all, so with only us attached its program
        /// waits until the pane is shown again, rather than running on in
        /// the background. When it is shown again its output is turned
        /// back on and the pane is re-read, since what tmux did read in
        /// the meantime was not sent to us.
        hidden_output_off_after: u32 = 0,

        /// Watch the order of the session's windows, and list them again
        /// when it changes. tmux sends a control client nothing when a
        /// window moves (`swap-window`, `move-window`, another client
        /// dragging a tab), so without this a GUI's tabs keep the order
        /// they had until something else re-lists the windows.
        ///
        /// A `refresh-client -B` subscription, so tmux 3.2 or newer. Off
        /// by default only because a scripted test of the viewer would
        /// have to answer the extra command.
        follow_window_order: bool = false,

        /// How to lay out the splits of the windows found on attach. See
        /// `AttachLayout`. Off by default, like `follow_window_order`,
        /// for scripted tests of the viewer.
        attach_layout: AttachLayout = .tmux,

        /// Mirror tmux's status line: `status-left`, the window list and
        /// `status-right`, as tmux formats them, delivered as `status`
        /// actions whenever any of them changes. Subscriptions too, so
        /// tmux 3.2 or newer.
        status_line: bool = false,

        /// Show each new pane's screen before reading its history, so a
        /// session with a lot of history appears at once rather than
        /// after all of it has crossed the wire. See `queuePaneReads`.
        ///
        /// Off by default because it reads every new pane's screen
        /// twice, and because the replies it adds are noise for anything
        /// that is not about attaching; a display wants it on.
        lazy_history: bool = false,

        /// The command line that started control mode in the host
        /// terminal, if it is known and running it again would reattach.
        /// See `host_command.read`. Copied; empty if unknown.
        ///
        /// Offered back to the user when the connection drops, which is
        /// all it is used for. It is the command that started *this*
        /// viewer, so a session switched to since is not where it leads.
        reattach_command: []const u8 = "",

        /// How many lines of a pane's history to read when it is read
        /// from scratch (on attach, for a new pane, and for one resumed
        /// from a pause), counted back from the screen. Null reads all of
        /// it; 0 reads none.
        ///
        /// The whole history of every pane is the largest thing an
        /// attach reads by far, and over a slow link it is what the user
        /// waits for. Whatever is left out stays in tmux; it is only not
        /// in our scrollback.
        history_limit: ?u32 = null,

        /// Read a pane's history this many lines at a time, or all at
        /// once if null.
        ///
        /// A read from scratch then takes only the newest lines, and
        /// older ones are read as the pane's display scrolls up to them,
        /// or as it needs all of them (`Input.history_wanted`), and go
        /// in above what it has. `history_limit` still caps how far back
        /// that goes. With a display that can ask, this is the cheap way
        /// to have it all: an attach, a pane resumed from a pause and a
        /// pane resized read the newest lines alone, and a pane nobody
        /// scrolls up through never has the rest read at all.
        ///
        /// It also means a pane tmux resized is read with its history,
        /// rather than its screens alone. Our scrollback and tmux's
        /// history each reflow by their own rules, so after a resize
        /// they no longer agree line for line, and older lines could not
        /// be placed above ours. See `syncLayouts`.
        history_chunk: ?u32 = null,

        /// Pass tmux's paste buffers on as `.paste_buffer` actions as
        /// they change, so that copying in tmux (copy mode, or
        /// `set-buffer` from a script) reaches the system clipboard.
        /// Needs tmux 3.2, the first to announce buffer changes.
        mirror_paste_buffers: bool = false,

        /// Further client flags to ask tmux for on attach. Needs tmux
        /// 3.2 for `refresh-client -f`; an older server is not asked. A
        /// flag a newer tmux added and an older one does not know is
        /// ignored by tmux without complaint.
        client_flags: ClientFlags = .{},
    };

    /// tmux's status line, as plain text. tmux's own styles (`#[fg=red]`)
    /// are taken out, since a GUI draws this its own way.
    pub const Status = struct {
        left: []const u8 = "",
        windows: []const u8 = "",
        right: []const u8 = "",

        fn deinit(self: Status, alloc: Allocator) void {
            inline for (.{ self.left, self.windows, self.right }) |part| {
                if (part.len > 0) alloc.free(part);
            }
        }
    };

    pub fn init(
        io: std.Io,
        alloc: Allocator,
        opts: Options,
    ) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        const reattach_command = try alloc.dupe(u8, opts.reattach_command);
        errdefer alloc.free(reattach_command);

        return .{
            .io = io,
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .tmux_version = "",
            .reattach_command = reattach_command,
            .command_queue = command_queue,
            .commands_sent = 0,
            .windows = .empty,
            .panes = .empty,
            .pause_after = opts.pause_after,
            .hidden_output_off_after = opts.hidden_output_off_after,
            .follow_window_order = opts.follow_window_order,
            .attach_layout = opts.attach_layout,
            .saved_layouts_known = opts.attach_layout != .restore,
            .status_line = opts.status_line,
            .lazy_history = opts.lazy_history,
            .history_limit = opts.history_limit,
            .history_chunk = opts.history_chunk,
            .mirror_paste_buffers = opts.mirror_paste_buffers,
            .client_flags = opts.client_flags,
            .paste_buffer = paste_buffer: {
                var token: [8]u8 = undefined;
                io.random(&token);
                var name: [paste_buffer_prefix.len + 16]u8 = undefined;
                _ = std.fmt.bufPrint(&name, "{s}{x}", .{
                    paste_buffer_prefix,
                    &token,
                }) catch unreachable;
                break :paste_buffer name;
            },
            .command_marker = command_marker: {
                var token: [8]u8 = undefined;
                io.random(&token);
                var name: [command_marker_prefix.len + 16]u8 = undefined;
                _ = std.fmt.bufPrint(&name, "{s}{x}", .{
                    command_marker_prefix,
                    &token,
                }) catch unreachable;
                break :command_marker name;
            },
            .current_window_id = null,
            .action_arena = .{},
            .action_single = undefined,
            .action_exit = undefined,
            .action_abandon = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.*.destroy(self.alloc);
            self.panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        if (self.session_name.len > 0) {
            self.alloc.free(self.session_name);
        }
        if (self.server_host.len > 0) {
            self.alloc.free(self.server_host);
        }
        if (self.server_home.len > 0) {
            self.alloc.free(self.server_home);
        }
        self.clearPendingNames();
        self.pending_names.deinit(self.alloc);
        self.status.deinit(self.alloc);
        self.alloc.free(self.reattach_command);
        self.clearSessions();
        self.sessions.deinit(self.alloc);
        self.action_arena.promote(self.alloc).deinit();
    }

    fn clearSessions(self: *Viewer) void {
        for (self.sessions.items) |session| self.alloc.free(session.name);
        self.sessions.clearRetainingCapacity();
    }

    /// Remember the session's name, replacing the one we had.
    fn setSessionName(self: *Viewer, name: []const u8) Allocator.Error!void {
        const owned = try self.alloc.dupe(u8, name);
        if (self.session_name.len > 0) self.alloc.free(self.session_name);
        self.session_name = owned;
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        if (self.read_only) {
            if (self.refuseReadOnly(input)) |actions| return actions;
        }

        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
            .write => self.nextWrite(input.write),
            .paste => self.nextPaste(input.paste),
            .resize => self.nextResize(input.resize),
            .client_size => self.nextClientSize(input.client_size),
            .new_window => self.nextNewWindow(input.new_window),
            .detach => self.nextDetach(),
            .select_pane => self.nextSelectPane(input.select_pane),
            .zoom_pane => self.nextZoomPane(input.zoom_pane),
            .move_window => self.nextMoveWindow(input.move_window),
            .rename_window => self.nextRenameWindow(input.rename_window),
            .split => self.nextSplit(input.split),
            .kill_windows => self.nextKillWindows(input.kill_windows),
            .kill_pane => self.nextKillPane(input.kill_pane),
            .pane_shown => self.nextPaneShown(input.pane_shown),
            .history_wanted => self.nextHistoryWanted(input.history_wanted),
            .read_history => self.nextReadHistory(input.read_history),
            .history_drifted => self.nextHistoryDrifted(input.history_drifted),
            .swap_pane => self.nextSwapPane(input.swap_pane),
            .rotate_window => self.nextRotateWindow(input.rotate_window),
            .break_pane => self.nextBreakPane(input.break_pane),
            .join_pane => self.nextJoinPane(input.join_pane),
            .move_pane => self.nextMovePane(input.move_pane),
            .command_line => self.nextCommandLine(input.command_line),
            .connection_lost => self.connectionLost(),
            .hide_window => self.nextHideWindow(input.hide_window),
            .switch_session => self.nextSwitchSession(input.switch_session),
            .list_sessions => self.nextListSessions(),
        };
    }

    /// What a read-only client does instead of `input`, or null if it
    /// may go ahead.
    ///
    /// tmux only enforces read-only for keys typed into a normal client:
    /// "only keys bound to the detach-client or switch-client commands
    /// have any effect". A control client has no keys, and the commands
    /// it sends are run whatever its flags (tmux 3.2 to 3.6 alike). So
    /// the GUI's keys and verbs, which stand in for a client's keys, are
    /// held to it here: the user, or whoever made this client read-only,
    /// meant it to watch, and a keystroke reaching a pane anyway would
    /// be a surprise for everyone else attached.
    ///
    /// The session keeps working otherwise. Output, layouts and the rest
    /// of tmux's notifications still arrive, and detaching still works.
    fn refuseReadOnly(self: *Viewer, input: Input) ?[]const Action {
        const refusal: Notice = .{
            .kind = .command_error,
            // tmux's own wording, for a command a read-only client may
            // not run.
            .text = "client is read-only",
        };

        if (input != .tmux) log.debug("read-only client refuses input={t}", .{input});

        switch (input) {
            // Not changes to the session. Our size is fine to report:
            // `-r` comes with `ignore-size`, so tmux does not size
            // anything after it while the client is read-only, and has
            // it already when the flag goes.
            .tmux,
            .client_size,
            .detach,
            .connection_lost,
            => return null,

            // Also what a read-only client may do: tmux lets its keys
            // run `switch-client`, and reading the session list is only
            // looking.
            .switch_session,
            .list_sessions,
            => return null,

            // What this client is sent, which is ours to decide: it is
            // the one thing `refresh-client` does that the session never
            // sees.
            .pane_shown => return null,

            // Only reading.
            .history_wanted,
            .read_history,
            .history_drifted,
            => return null,

            // Side effects of the GUI, not something the user asked
            // tmux for: a surface being laid out or focused. Nothing to
            // tell them, and focus still moves here, just not in tmux.
            .resize,
            .select_pane,
            => return &.{},

            // Typing. Said once in a while rather than per keystroke.
            .write,
            .paste,
            => {
                const now = std.Io.Timestamp.now(self.io, .awake);
                if (self.read_only_noticed) |last| {
                    const quiet: std.Io.Duration = .fromSeconds(3);
                    if (last.durationTo(now).nanoseconds < quiet.nanoseconds) {
                        return &.{};
                    }
                }
                self.read_only_noticed = now;
                return self.singleAction(.{ .notice = refusal });
            },

            // Something the user asked tmux for in so many words.
            .new_window,
            .zoom_pane,
            .move_window,
            .rename_window,
            .split,
            .kill_windows,
            .kill_pane,
            .swap_pane,
            .rotate_window,
            .break_pane,
            .join_pane,
            .move_pane,
            => return self.singleAction(.{ .notice = refusal }),

            // tmux does not let a read-only client open its command
            // prompt either: only keys bound to detaching or switching
            // sessions do anything there.
            .command_line,
            => return self.singleAction(.{ .notice = refusal }),

            // Only our view of the session, but kept on the window in
            // tmux, where every other client of ours would see it.
            .hide_window,
            => return self.singleAction(.{ .notice = refusal }),
        }
    }

    /// Ask tmux to resize a pane.
    ///
    /// Two things can need to change, because a pane can never be larger
    /// than the tmux window holding it: the window's size, and the pane's
    /// share of that window. A pane that is alone in its window only needs
    /// the first, since it always fills whatever the window is.
    ///
    /// Deduplicated against the last size we asked for, not against the
    /// pane's current size: tmux clamps a resize to what the layout allows,
    /// so comparing against the result would make us re-send the same
    /// request forever.
    fn nextResize(self: *Viewer, r: Input.Resize) []const Action {
        if (self.state != .command_queue) return &.{};
        if (r.cols == 0 or r.rows == 0) return &.{};

        const pane: *Pane = (self.panes.getEntry(r.pane_id) orelse {
            log.info("resize of unknown pane id={}, dropping", .{r.pane_id});
            return &.{};
        }).value_ptr.*;

        const maybe_window: ?*Window = self.windowForPane(r.pane_id);

        // A pane hidden behind a zoomed one has no say in anything: tmux
        // is not showing it, and the window is sized from the zoomed
        // pane alone. Whatever its surface makes of being hidden is not
        // a size to ask for, and kept, it would mix into the window
        // composed from the layout once the zoom ends.
        if (maybe_window) |w| {
            if (!layoutContainsPane(w.shownLayout(), r.pane_id)) return &.{};
        }

        // A report of exactly the size the last layout took away from
        // this pane, before any report computed under that layout, is a
        // stale echo: it was computed from the tree the layout replaced
        // and only arrived after. Recording it would let it complete a
        // sibling's fresh set, and the mixed batch asks tmux for a
        // window neither layout describes -- which moves the divider,
        // relays the GUI out, and starts the same exchange again, with
        // no fixed point. Held: the layout resized this pane, so its
        // surface still owes us a report, and that report completes the
        // set instead.
        if (pane.stale_size) |stale| {
            if (r.cols == stale.cols and r.rows == stale.rows) return &.{};

            // Any other size was computed under the new layout: reports
            // from one surface arrive in the order they were computed,
            // so nothing stale can follow it.
            pane.stale_size = null;
        }

        // Recorded before anything can skip out: a pane asking again for
        // the size it already asked for still counts towards its window
        // being fully spoken for, and dropping it here would leave the
        // window waiting on a pane with nothing left to say.
        pane.last_resize_request = .{ .cols = r.cols, .rows = r.rows };

        const window: *Window = maybe_window orelse return &.{};
        const shown = window.shownLayout();

        // Panes are relaid out together but report one at a time, and a
        // window's size is composed from all of them. Filling in the
        // panes that have not reported yet with the size tmux last gave
        // them composes a window neither side ever asked for; tmux
        // honours it, the divider moves, the GUI relays out, and every
        // pane reports again. That loop has no fixed point -- it walks
        // the divider a cell per round trip for as long as it runs. So
        // nothing goes out until every pane in the window has spoken.
        //
        // Except when the window as a whole is not changing size. A
        // surface only reports when its own size changes, so dragging a
        // divider inside one side of a split ({A | [B / C]}, moving the
        // B/C divider) has B and C report and A say nothing, ever: A was
        // not resized. Waiting for A would ignore the drag for good.
        // There is nothing to mix up here, because no window size is
        // being composed: if the panes that did report, with the rest at
        // the sizes tmux has them, add up to the window tmux already
        // has, the reports describe a rearrangement inside it, and the
        // panes are resized on their own. A report that changes the
        // window's size still waits for every pane, so a half-reported
        // relayout (B in, C still in flight) does not add up and waits.
        // And a report of the size a pane already has asks for nothing,
        // so it waits for company rather than going out alone.
        //
        // Adding up means fitting together, as tmux's panes always do:
        // the children of a split the same size across it. Composed the
        // way a window is, the largest child sets that size, and a pane
        // narrower than its sibling disappears into it. That is a pane
        // of a smaller GUI window reporting ahead of the rest, not a
        // drag, and let through one by one such reports kept the window
        // at tmux's size for good, with its panes shuffled about inside.
        //
        // Nor while a size we asked for is on its way. The layout we
        // have is then the old one, and a pane reporting against the
        // new arrangement, with the rest filled in from the old, can
        // add up to the old size: going out, it would ask tmux for that
        // size back.
        //
        // All of this is over the panes on screen. While a pane is
        // zoomed that is the zoomed pane alone, which is the window:
        // composing the unzoomed layout around its full-window size
        // would ask tmux for a window as much bigger as the panes
        // hidden behind it.
        //
        // The window's size is the shown layout's, which is what tmux
        // last laid it out at; `Window.width` is only as of the last
        // `list-windows`.
        if (!layoutFullyRequested(&self.panes, shown)) {
            const fitted = fitLayoutSize(&self.panes, shown) orelse return &.{};
            if (fitted.cols != shown.width or
                fitted.rows != shown.height or
                window.sizePending() or
                !layoutRequestsChange(&self.panes, shown)) return &.{};
        }

        return self.queueResize(window) catch |err| {
            log.warn(
                "failed to queue resize for window id={} err={}",
                .{ window.id, err },
            );
            return &.{};
        };
    }

    /// Whether every pane in the layout has an unanswered resize request.
    ///
    /// A pane tmux left alone in the last layout keeps its request, which
    /// is what we want: tmux agreeing with a request does not make it
    /// stale, and that pane has no reason to report again.
    fn layoutFullyRequested(panes: *const PanesMap, node: Layout) bool {
        return switch (node.content) {
            .pane => |id| if (panes.get(id)) |pane|
                pane.last_resize_request != null
            else
                false,

            .horizontal, .vertical => |children| for (children) |child| {
                if (!layoutFullyRequested(panes, child)) break false;
            } else true,
        };
    }

    /// Whether any pane in the layout is asking for a size other than
    /// the one tmux has it at.
    fn layoutRequestsChange(panes: *const PanesMap, node: Layout) bool {
        return switch (node.content) {
            .pane => |id| pane: {
                const pane = panes.get(id) orelse break :pane false;
                const want = pane.last_resize_request orelse break :pane false;
                break :pane want.cols != pane.terminal.cols or
                    want.rows != pane.terminal.rows;
            },

            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutRequestsChange(panes, child)) break true;
            } else false,
        };
    }

    fn queueResize(
        self: *Viewer,
        window: *Window,
    ) Allocator.Error![]const Action {
        var commands: std.ArrayList(Command) = .empty;
        defer commands.deinit(self.alloc);
        errdefer for (commands.items) |c| c.deinit(self.alloc);

        // The window first: growing a pane into space the window does not
        // have yet would just be clamped away.
        var lone_pane_covered = false;
        if (try self.windowResizeCommand(window)) |result| {
            if (result.command) |c| {
                try commands.append(self.alloc, c);

                // A lone pane is its window, so `resize-pane` could only
                // ask for the size we just asked for.
                lone_pane_covered = result.only_pane_in_window;
            }
        }

        // A zoomed pane is sized with its window and never on its own:
        // tmux unzooms a window before resizing any pane in it, so a
        // `resize-pane` here would undo the zoom the GUI is showing.
        if (window.zoomed_layout != null) lone_pane_covered = true;

        // A window found on attach is laid out whole, at the size just
        // asked for, which sizes every pane in it. Their own requests
        // were made against the layout it replaces.
        if (try self.arrangeCommand(window)) |c| {
            errdefer c.deinit(self.alloc);
            try commands.append(self.alloc, c);
            lone_pane_covered = true;
        }

        try self.appendPaneResizes(
            window.shownLayout(),
            &commands,
            lone_pane_covered,
        );

        if (commands.items.len == 0) return &.{};

        // The commands themselves pass to the queue; the list holding
        // them is ours to free either way.
        return self.queueUserCommands(commands.items);
    }

    /// Append a `resize-pane` for each pane in the layout that wants a
    /// size it has not already been told to take, in layout order.
    ///
    /// `covered` is for the lone pane whose window we just sized: that
    /// command already gave it the size it asked for, so it needs no
    /// command of its own but must still be marked as asked, or the next
    /// identical request would go out as a `resize-pane`.
    fn appendPaneResizes(
        self: *Viewer,
        node: Layout,
        commands: *std.ArrayList(Command),
        covered: bool,
    ) Allocator.Error!void {
        switch (node.content) {
            .pane => |id| {
                const pane: *Pane = self.panes.get(id) orelse return;
                const want = pane.last_resize_request orelse return;

                // Spent: this batch is the answer to it. Leaving it would
                // let the next single pane to report find the set already
                // complete and compose a window out of one fresh size and
                // one from the round before -- the very mixture the set
                // exists to prevent. One batch per full set of reports.
                pane.last_resize_request = null;

                // Against what we last sent, not against the pane's
                // current size: tmux answers a resize with a layout of
                // its own choosing, so the surface may well ask for the
                // same size again. Re-sending it is not one wasted round
                // trip but a loop with no end.
                if (pane.last_resize_sent) |last| {
                    if (last.cols == want.cols and last.rows == want.rows) return;
                }

                if (!covered) {
                    const command = try self.userCommand(
                        "resize-pane -t %{d} -x {d} -y {d}\n",
                        .{ id, want.cols, want.rows },
                    );
                    errdefer command.deinit(self.alloc);

                    try commands.append(self.alloc, command);
                }

                pane.last_resize_sent = .{ .cols = want.cols, .rows = want.rows };
            },

            .horizontal, .vertical => |children| for (children) |child| {
                try self.appendPaneResizes(child, commands, covered);
            },
        }
    }

    const WindowResize = struct {
        /// Null when the window is already the size we want, or when tmux
        /// is too old to be told.
        command: ?Command,
        only_pane_in_window: bool,
    };

    /// Build the command that sizes the tmux window holding `pane_id`.
    ///
    /// tmux lays every window out inside its client's size, so a control
    /// client that reports one size gets one size for all of its windows.
    /// That is wrong for us: each tmux window is its own native window and
    /// has its own size. `refresh-client -C @id:WxH` sets a per-window size
    /// that `clients_calculate_size` uses in place of the client's own for
    /// that window (see tmux's resize.c), which is exactly what we want.
    ///
    /// The size comes from the panes rather than from the apprt, because
    /// the viewer is what knows the layout: composing the panes' requested
    /// sizes the same way tmux composes a layout gives the size the native
    /// window is asking for, dividers included.
    ///
    fn windowResizeCommand(
        self: *Viewer,
        window: *Window,
    ) Allocator.Error!?WindowResize {
        // While a pane is zoomed it is the only one on screen, and so
        // the only one the window is sized from. See `shownLayout`.
        const shown = window.shownLayout();
        const want = composeLayoutSize(&self.panes, shown);
        const only = shown.content == .pane;

        if (window.last_size_request) |last| {
            if (last.cols == want.cols and last.rows == want.rows) {
                return .{ .command = null, .only_pane_in_window = only };
            }
        }

        window.last_size_request = .{ .cols = want.cols, .rows = want.rows };

        // Whoever had the window, this asks for it back; whether tmux
        // agrees is for the layout answering it to say.
        window.size_taken = false;

        // Per-window sizes through `refresh-client -C @id:WxH` landed in
        // tmux 3.4. An older server parses that argument as a plain size,
        // fails, and answers with an error, so it gets `resize-window`
        // instead -- which is what iTerm2 does, and which reaches the
        // same place by a blunter route: it pins the window's size by
        // setting `window-size` to manual for it, a server side change
        // that outlives us. Worth it, because the alternative is a window
        // stuck at whatever size the host surface happens to be.
        const command = if (self.tmuxVersionAtLeast(3, 4))
            try self.userCommand(
                "refresh-client -C @{d}:{d}x{d}\n",
                .{ window.id, want.cols, want.rows },
            )
        else
            try self.userCommand(
                "resize-window -x {d} -y {d} -t @{d}\n",
                .{ want.cols, want.rows, window.id },
            );

        return .{
            .command = command,
            .only_pane_in_window = only,
        };
    }

    /// The window containing the given pane, if any.
    fn windowForPane(self: *Viewer, pane_id: usize) ?*Window {
        for (self.windows.items) |*window| {
            if (layoutContainsPane(window.layout, pane_id)) return window;
        }
        return null;
    }

    /// The first pane in a layout, in tree order.
    ///
    /// Used on a *visible* layout, where tmux collapses a zoomed window
    /// to the single pane it is showing, so "first" is "the zoomed one".
    fn firstPaneId(node: Layout) ?usize {
        return switch (node.content) {
            .pane => |id| id,
            .horizontal, .vertical => |children| for (children) |child| {
                if (firstPaneId(child)) |id| break id;
            } else null,
        };
    }

    /// What tmux shows of a zoomed window, from its own account of it, or
    /// null if the window is not zoomed. The zoomed pane is the one in
    /// it: see `firstPaneId`.
    ///
    /// `flags` is tmux's window flags string, where 'Z' means zoomed.
    /// Only 'Z' is read: tmux formats these against the window's first
    /// winlink, so the session flags in there ('*', '-') are not
    /// necessarily true of *this* client.
    ///
    /// The pane comes from the visible layout rather than from tmux's
    /// active pane, which we only learn lazily and only for the current
    /// window -- a window already zoomed when we attached would have no
    /// active pane recorded at all.
    ///
    /// A visible layout we cannot parse means unzoomed, not fatal: this
    /// decides how a window is drawn, and drawing it unzoomed is a great
    /// deal better than ending the session over it.
    pub fn zoomedLayout(
        alloc: Allocator,
        flags: []const u8,
        visible_layout: []const u8,
    ) ?Layout {
        if (std.mem.indexOfScalar(u8, flags, 'Z') == null) return null;

        const layout = Layout.parseWithChecksum(alloc, visible_layout) catch {
            log.info(
                "failed to parse visible layout, treating as unzoomed: {s}",
                .{visible_layout},
            );
            return null;
        };

        // A layout with no pane in it has nothing to be zoomed to.
        if (firstPaneId(layout) == null) return null;
        return layout;
    }

    fn layoutContainsPane(node: Layout, pane_id: usize) bool {
        return switch (node.content) {
            .pane => |id| id == pane_id,
            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutContainsPane(child, pane_id)) break true;
            } else false,
        };
    }

    /// Like `composeLayoutSize`, but only if the sizes fit together as
    /// tmux's do: the children of each split all the same size across
    /// it. Null if they do not, as when some panes have reported against
    /// an arrangement the rest have not caught up with.
    fn fitLayoutSize(
        panes: *const PanesMap,
        node: Layout,
    ) ?struct { cols: usize, rows: usize } {
        const children: []const Layout, const across: bool = switch (node.content) {
            .pane => {
                const own = composeLayoutSize(panes, node);
                return .{ .cols = own.cols, .rows = own.rows };
            },
            .horizontal => |v| .{ v, true },
            .vertical => |v| .{ v, false },
        };

        // Along the split, the children and a divider between each pair.
        var along: usize = children.len -| 1;
        var other: ?usize = null;
        for (children) |child| {
            const fitted = fitLayoutSize(panes, child) orelse return null;
            along += if (across) fitted.cols else fitted.rows;
            const o = if (across) fitted.rows else fitted.cols;
            if (other) |v| if (v != o) return null;
            other = o;
        }

        return if (across)
            .{ .cols = along, .rows = other orelse 0 }
        else
            .{ .cols = other orelse 0, .rows = along };
    }

    /// The size a layout would need to hold every pane at the size that
    /// pane last asked for, falling back to the size tmux gave it.
    ///
    /// This is tmux's own composition: a split costs one cell for the
    /// divider between each pair of children, and the other axis is the
    /// largest child. See `layout_fix_offsets` in tmux's layout.c.
    fn composeLayoutSize(
        panes: *const PanesMap,
        node: Layout,
    ) struct { cols: usize, rows: usize } {
        switch (node.content) {
            .pane => |id| {
                if (panes.get(id)) |pane| {
                    if (pane.last_resize_request) |r| {
                        return .{ .cols = r.cols, .rows = r.rows };
                    }
                }
                return .{ .cols = node.width, .rows = node.height };
            },

            .horizontal => |children| {
                var cols: usize = children.len -| 1;
                var rows: usize = 0;
                for (children) |child| {
                    const child_size = composeLayoutSize(panes, child);
                    cols += child_size.cols;
                    rows = @max(rows, child_size.rows);
                }
                return .{ .cols = cols, .rows = rows };
            },

            .vertical => |children| {
                var cols: usize = 0;
                var rows: usize = children.len -| 1;
                for (children) |child| {
                    const child_size = composeLayoutSize(panes, child);
                    cols = @max(cols, child_size.cols);
                    rows += child_size.rows;
                }
                return .{ .cols = cols, .rows = rows };
            },
        }
    }

    /// The oldest tmux we support. Control mode itself is far older, but
    /// we rely on what 3.2 added to it: `%pause` and `%continue`,
    /// `refresh-client -f` and `-A`, and the `list-panes` formats the
    /// attach reads every pane's state with. An older server attaches
    /// happily and then fails piecemeal, so it is turned away up front
    /// instead. See `refuseOldTmux`.
    const min_tmux_release: Release = .{ .major = 3, .minor = 2 };

    /// A tmux release, `major.minor`, as compared by `tmuxRelease`.
    const Release = struct {
        major: usize,
        minor: usize,

        fn atLeast(self: Release, other: Release) bool {
            if (self.major != other.major) return self.major > other.major;
            return self.minor >= other.minor;
        }
    };

    /// The release of the tmux we are talking to, or null if its version
    /// cannot be read.
    ///
    /// tmux reports versions like `3.5a`, where the letter is a bug-fix
    /// release, so only the leading `major.minor` counts. A build from
    /// tmux's git tree calls itself `next-3.7`: the release it is on its
    /// way to, and newer than every release before it, so it counts as
    /// that one. Anything else (`master`, a distribution's own scheme
    /// such as OpenBSD's `openbsd-7.6`) is unreadable.
    fn tmuxRelease(self: *const Viewer) ?Release {
        const version = if (std.mem.startsWith(u8, self.tmux_version, "next-"))
            self.tmux_version["next-".len..]
        else
            self.tmux_version;
        var it = std.mem.splitScalar(u8, version, '.');
        const major_str = it.next() orelse return null;
        const minor_str = it.next() orelse return null;

        const major = std.fmt.parseInt(usize, major_str, 10) catch
            return null;

        // Trim any bug-fix letter, e.g. the `a` of `3.5a`.
        const digits = end: {
            var end: usize = 0;
            while (end < minor_str.len and std.ascii.isDigit(minor_str[end])) {
                end += 1;
            }
            break :end minor_str[0..end];
        };
        const minor = std.fmt.parseInt(usize, digits, 10) catch
            return null;

        return .{ .major = major, .minor = minor };
    }

    /// Whether the tmux we are talking to is at least the given version.
    /// An unreadable version answers false: a feature we cannot confirm
    /// is a feature we do not use.
    fn tmuxVersionAtLeast(self: *const Viewer, major: usize, minor: usize) bool {
        const release = self.tmuxRelease() orelse return false;
        return release.atLeast(.{ .major = major, .minor = minor });
    }

    /// Whether the tmux we are talking to is known to be older than we
    /// support. An unreadable version is given the benefit of the doubt:
    /// it is far more likely a packager's naming than a tmux from before
    /// 2020, and refusing it would lock its users out entirely.
    fn tmuxTooOld(self: *const Viewer) bool {
        const release = self.tmuxRelease() orelse return false;
        return !release.atLeast(min_tmux_release);
    }

    /// Tell tmux the size of our control mode client.
    fn nextClientSize(self: *Viewer, c: Input.ClientSize) []const Action {
        if (self.state != .command_queue) return &.{};
        if (c.cols == 0 or c.rows == 0) return &.{};

        if (self.last_client_size) |last| {
            if (last.cols == c.cols and last.rows == c.rows) return &.{};
        }
        self.last_client_size = .{ .cols = c.cols, .rows = c.rows };

        return self.queueUserCommand("refresh-client -C {d}x{d}\n", .{
            c.cols,
            c.rows,
        }) catch {
            log.warn("failed to queue client size", .{});
            return &.{};
        };
    }

    /// Ask tmux for a new window.
    ///
    /// `-a` puts it right after the window the user asked from, moving
    /// later windows along if they are in the way. Without it tmux takes
    /// the lowest free index, which is the end only while the indexes
    /// have no gaps: in a session where a window was closed and
    /// `renumber-windows` is off, every new tab would land in that gap.
    ///
    /// Targeted at the pane's window rather than tmux's current one,
    /// which can be behind the user (a `select-window` still on its way)
    /// or somewhere else entirely (another client moved it). With no
    /// window to go by, tmux's current one is the best guess left.
    ///
    /// The `%window-add` that follows is what makes it appear here, so
    /// nothing needs to be remembered in between.
    fn nextNewWindow(self: *Viewer, req: Input.NewWindow) []const Action {
        if (self.state != .command_queue) return &.{};

        const window = if (req.pane_id) |id| self.windowForPane(id) else null;
        const directory = self.startDirectory(
            if (req.inherit_working_directory) req.pane_id else null,
        );
        const queued = if (window) |w|
            self.queueUserCommand("new-window -a -t @{d}{f}\n", .{ w.id, directory })
        else
            self.queueUserCommand("new-window -a{f}\n", .{directory});
        return queued catch {
            log.warn("failed to queue new-window", .{});
            return &.{};
        };
    }

    /// tmux says which window the session is on.
    ///
    /// tmux's notifications say what *is*, not what changed: one is
    /// written when tmux gets round to it, after the replies to the
    /// commands that caused it, and carries the session's window at that
    /// moment. A quick A-then-B from us is answered with B twice, never
    /// with A. So this is not matched against what we asked for; it is
    /// compared with where our own selects will have left tmux
    /// (`current_window_id`, which `queueSelect` moves as it sends them):
    ///
    ///   - While a `select-window` of ours is unanswered, this may be
    ///     from before it ran, and it is ignored. Ours either moves tmux,
    ///     which tmux reports again once it has, or finds it already
    ///     there, which is where we have it.
    ///   - Otherwise it is from after all of ours. Where we have it
    ///     already, it says nothing new. Anywhere else, something other
    ///     than us moved tmux -- another client, a script, a binding --
    ///     and the GUI follows.
    ///
    /// Nothing here sends a command, so the GUI following cannot start a
    /// loop: its focus lands where `current_window_id` already is, and
    /// `nextSelectPane` finds nothing to send for it. That is the lesson
    /// from iTerm2, whose `TmuxController` documents the livelock that
    /// echoing a command back at a notification causes.
    fn sessionWindowChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        window_id: usize,
    ) !void {
        // tmux tells every control client about every session. Another
        // session's window, even one linked into ours, is not ours to
        // move to.
        if (self.session_id != session_id) return;
        if (self.windowSelectUnanswered()) return;

        // A window we have never heard of is not one the GUI can focus.
        // The layout that introduces it will arrive on its own, carrying
        // this same current-window flag with it. Recorded even so: it is
        // where tmux is, so a focus here in the meantime is a move.
        const window: *Window = for (self.windows.items) |*w| {
            if (w.id == window_id) break w;
        } else {
            log.info("current window id={} unknown, not focusing", .{window_id});
            self.current_window_id = window_id;
            return;
        };

        if (self.current_window_id == window_id and window.active) return;

        self.setCurrentWindow(window_id);

        // Re-send the window list rather than inventing an action for
        // one field. The GUI already diffs this on every change, and
        // which window is current is a fact about the set.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), .{ .windows = self.windows.items });
    }

    /// Make `window_id` the session's current window, flags and all.
    fn setCurrentWindow(self: *Viewer, window_id: usize) void {
        self.current_window_id = window_id;
        for (self.windows.items) |*w| {
            w.active = w.id == window_id;

            // tmux clears a window's alerts as the session moves to it
            // (`winlink_clear_flags`), so there is nothing to wait for.
            if (w.active) w.alerts = .{};
        }
    }

    /// tmux says which pane is active in a window.
    ///
    /// The same rule as `sessionWindowChanged`, per window: ignored
    /// while a `select-pane` of ours in that window is unanswered,
    /// nothing new where we have it already, and otherwise news the GUI
    /// follows. A pane closing, a split (the new pane is made active),
    /// another client or a binding typed in a pane all move it.
    fn windowPaneChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        pane_id: usize,
    ) !void {
        const window: *Window = for (self.windows.items) |*w| {
            if (w.id == window_id) break w;
        } else {
            // Its window list is on the way and will say the same.
            log.info("active pane of unknown window id={}", .{window_id});
            return;
        };

        if (self.paneSelectUnanswered(window_id)) return;
        if (window.active_pane_id == pane_id) return;
        window.active_pane_id = pane_id;

        // Re-send the window list, as for the current window: which pane
        // is active is a fact about the set the GUI already diffs.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), .{ .windows = self.windows.items });
    }

    /// Whether a `select-window` of ours is still waiting for its reply.
    /// Every command is sent as soon as it is queued, so queued is sent.
    fn windowSelectUnanswered(self: *const Viewer) bool {
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |command| {
            if (command.* == .select_window) return true;
        }
        return false;
    }

    /// Whether a `select-pane` of ours in `window_id` is still waiting
    /// for its reply.
    fn paneSelectUnanswered(self: *const Viewer, window_id: usize) bool {
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |command| switch (command.*) {
            .select_pane => |s| if (s.window_id == window_id) return true,
            else => {},
        };
        return false;
    }

    /// Write a window name as a single tmux command argument.
    ///
    /// This is the only place in the stack where user text becomes part
    /// of a command (a pane's working directory, from `startDirectory`,
    /// comes through here too), so it is worth setting out exactly what
    /// is being defended against. A name has to survive two layers, and
    /// quoting only helps with one of them.
    ///
    /// 1. **Control bytes are dropped**, the newline above all. tmux
    ///    reads control mode input a line at a time
    ///    (`evbuffer_readln(EVBUFFER_EOL_LF)` in control.c), so a raw
    ///    newline in what we send *ends the command* and everything
    ///    after it is read as another one. Quoting cannot save this:
    ///    the line is split before the parser sees a quote. Nothing is
    ///    lost by dropping them -- tmux itself runs a stored name
    ///    through `utf8_stravis` and would not have shown them either.
    ///
    /// 2. **`#` is doubled.** `rename-window` puts its argument through
    ///    format expansion *after* the parser has removed the quotes
    ///    (`format_single_from_target` in cmd-rename-window.c), so
    ///    `#(cmd)` starts a shell job and `#{var}` expands, single
    ///    quotes or not. `##` is the format escape for a literal `#`.
    ///
    /// 3. **Single quotes around the result**, with an embedded quote
    ///    written `'\''`. Inside single quotes tmux's lexer takes every
    ///    byte literally, so `;`, `$`, backslash and the rest stop
    ///    meaning anything.
    ///
    /// The caller is responsible for the `--` that keeps a name starting
    /// with `-` from being read as a flag.
    pub fn writeQuotedName(writer: *std.Io.Writer, name: []const u8) !void {
        try writer.writeByte('\'');
        for (name) |c| {
            // C0 and DEL. See (1): these cannot be quoted around.
            if (c < 0x20 or c == 0x7F) continue;

            switch (c) {
                // See (2). Doubled before quoting, because expansion
                // happens after unquoting.
                '#' => try writer.writeAll("##"),

                // See (3). Close, escape, reopen.
                '\'' => try writer.writeAll("'\\''"),

                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('\'');
    }

    /// The `-c` that starts a new pane or window where a pane is, as
    /// plain Ghostty starts a new split or tab in the directory of the
    /// surface it came from. See `StartDirectory`.
    ///
    /// The directory is the one tmux last reported for the pane (see
    /// `Pane.path`), not tmux's own `-c '#{pane_current_path}'`, the
    /// usual way to say this in a tmux binding: tmux expands that
    /// against the active pane of the session's current window,
    /// whatever `-t` names (spawn.c gives the expansion no pane, and
    /// format.c falls back to that one). The pane the user asked from
    /// is not always that one --
    /// focus may not have reached tmux yet, another client may have
    /// moved it, and `new-window` has no pane to target at all. The
    /// subscription keeps the reported one current to within a second.
    fn startDirectory(self: *const Viewer, pane_id: ?usize) StartDirectory {
        const id = pane_id orelse return .{ .path = null };
        const pane = self.panes.get(id) orelse return .{ .path = null };

        // tmux has not said yet, or could not find out.
        if (pane.path.len == 0) return .{ .path = null };

        // A path that `writeQuotedName` would have to change to send
        // is not the pane's directory any more; tmux's own default is
        // a better place to start than somewhere else.
        for (pane.path) |c| if (c < 0x20 or c == 0x7F) {
            return .{ .path = null };
        };

        return .{ .path = pane.path };
    }

    /// Formats as ` -c <path>`, quoted, for a command line, or as
    /// nothing at all without a path: tmux then starts the pane in its
    /// default (`default-path`, or the session's directory), as plain
    /// Ghostty does with nothing to inherit from.
    ///
    /// Quoted like a window name, and for the same reasons: tmux puts
    /// `-c` through format expansion after unquoting it (`spawn.c`), so
    /// a `#` in a directory name needs doubling as much as one in a
    /// window name does.
    const StartDirectory = struct {
        path: ?[]const u8,

        pub fn format(
            self: StartDirectory,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const path = self.path orelse return;
            try writer.writeAll(" -c ");
            try writeQuotedName(writer, path);
        }
    };

    /// Ask tmux to rename the window a pane is in.
    ///
    /// An empty name means "stop overriding", which in tmux is not an
    /// empty name but `automatic-rename` back on: `rename-window` turns
    /// that option *off* as a side effect, so renaming to "" would pin
    /// the window to a blank name forever rather than returning it to
    /// naming itself after what it is running.
    fn nextRenameWindow(self: *Viewer, req: Input.RenameWindow) []const Action {
        if (self.state != .command_queue) return &.{};

        const window = self.windowForPane(req.pane_id) orelse {
            log.info("rename for pane id={} in no window", .{req.pane_id});
            return &.{};
        };

        if (req.name.len == 0) {
            return self.queueUserCommand(
                "set-option -w -t @{d} automatic-rename on\n",
                .{window.id},
            ) catch {
                log.warn("failed to queue automatic-rename", .{});
                return &.{};
            };
        }

        return self.queueRename(window.id, req.name) catch {
            log.warn("failed to queue rename-window", .{});
            return &.{};
        };
    }

    fn queueRename(
        self: *Viewer,
        window_id: usize,
        name: []const u8,
    ) Allocator.Error![]const Action {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();

        // `--` so a name beginning with `-` is an argument and not a
        // flag: tmux's argument parser would otherwise reject it.
        builder.writer.print(
            "rename-window -t @{d} -- ",
            .{window_id},
        ) catch return error.OutOfMemory;
        writeQuotedName(&builder.writer, name) catch return error.OutOfMemory;
        builder.writer.writeByte('\n') catch return error.OutOfMemory;

        const command: Command = .{ .user = try builder.toOwnedSlice() };
        errdefer command.deinit(self.alloc);

        var one = [_]Command{command};
        return self.queueUserCommands(&one);
    }

    /// Move a window along the session's window order.
    ///
    /// `swap-window` rather than `move-window`: swapping exchanges two
    /// windows' indexes and leaves every other window where it was,
    /// which is what dragging a tab one place along means. `move-window`
    /// renumbers, and with no free index it fails outright.
    ///
    /// Further than one place is one swap per place, with each window in
    /// between in turn, so that those windows each move back one and keep
    /// their order -- which is what dragging a tab several places along
    /// means. A single swap with the window at the far end would trade
    /// the two and leave the tab strip in an order nobody asked for.
    ///
    /// The neighbour is resolved from the viewer's own ordered window
    /// list rather than by arithmetic on tmux indexes, because those are
    /// sparse: killing window 1 of 0,1,2 leaves 0,2, and "one to the
    /// right of 0" is 2, not 1.
    ///
    /// The window list is asked for again straight after. tmux does not
    /// tell a control client that windows moved -- `swap-window` sends no
    /// notification at all -- so this is how the new order reaches us,
    /// and through us the GUI's tabs.
    ///
    /// Moving past either end does nothing. A tab at the end that
    /// silently stays there is what every other tab strip does.
    fn nextMoveWindow(self: *Viewer, req: Input.MoveWindow) []const Action {
        if (self.state != .command_queue) return &.{};
        if (req.amount == 0) return &.{};

        const window = self.windowForPane(req.pane_id) orelse {
            log.info("move for pane id={} in no window", .{req.pane_id});
            return &.{};
        };

        const from: isize = for (self.windows.items, 0..) |w, i| {
            if (w.id == window.id) break @intCast(i);
        } else return &.{};

        const to = from + req.amount;
        if (to < 0 or to >= self.windows.items.len) return &.{};

        return self.queueSwaps(window.id, from, to) catch {
            log.warn("failed to queue swap-window", .{});
            return &.{};
        };
    }

    fn queueSwaps(
        self: *Viewer,
        window_id: usize,
        from: isize,
        to: isize,
    ) Allocator.Error![]const Action {
        var commands: std.ArrayList(Command) = .empty;
        defer commands.deinit(self.alloc);

        {
            errdefer for (commands.items) |c| c.deinit(self.alloc);

            const step: isize = if (to > from) 1 else -1;
            var i = from;
            while (i != to) {
                i += step;
                const other = self.windows.items[@intCast(i)];

                // -d so the swap does not drag the current window along
                // with it: moving a tab is not a request to look at it.
                const command = try self.userCommand(
                    "swap-window -d -s @{d} -t @{d}\n",
                    .{ window_id, other.id },
                );
                errdefer command.deinit(self.alloc);
                try commands.append(self.alloc, command);
            }
            try commands.append(self.alloc, .list_windows);
        }

        // The commands pass to the queue, success or not; the list
        // holding them is ours to free either way.
        return self.queueUserCommands(commands.items);
    }

    /// Ask tmux to toggle zoom on a pane.
    ///
    /// Nothing is changed here and nothing is remembered. tmux owns
    /// whether a window is zoomed, answers with a `%layout-change`, and
    /// that is what moves the GUI -- so the two cannot drift apart for
    /// longer than one round trip. Toggling locally as well would show
    /// the user a zoom that tmux had not agreed to.
    ///
    /// `-Z` is a toggle on the *window*, not on the pane: if some other
    /// pane were zoomed, this unzooms rather than moving the zoom here.
    /// Only the zoomed pane is rendered while a window is zoomed, so a
    /// user cannot reach another pane to ask; a binding that jumps panes
    /// makes tmux unzoom on its own first.
    fn nextZoomPane(self: *Viewer, req: Input.ZoomPane) []const Action {
        if (self.state != .command_queue) return &.{};
        if (!self.panes.contains(req.pane_id)) {
            log.info("zoom of unknown pane id={}, dropping", .{req.pane_id});
            return &.{};
        }

        return self.queueUserCommand(
            "resize-pane -Z -t %{d}\n",
            .{req.pane_id},
        ) catch {
            log.warn("failed to queue resize-pane -Z", .{});
            return &.{};
        };
    }

    /// Tell tmux which pane the user is in.
    ///
    /// `select-pane` moves the active pane within its window, which is
    /// what focus means here. It is visible to every other client
    /// attached to the session -- iTerm2 does the same thing from its own
    /// focus changes, and the alternative is that tmux's idea of "the
    /// active pane" has nothing to do with where the user is typing.
    ///
    /// Only what tmux does not have already is sent, judged by where our
    /// selects so far will have left it (see `sessionWindowChanged`).
    /// That is not an optimisation. Focus can flap several times in a
    /// drag or a window switch, and tmux runs our commands strictly in
    /// order, so everything the user does after that runs behind each
    /// repeat -- including the `send-keys` carrying their keystrokes. It
    /// is also what makes the GUI following tmux settle: focus landing
    /// on the pane tmux just reported sends nothing.
    fn nextSelectPane(self: *Viewer, req: Input.SelectPane) []const Action {
        if (self.state != .command_queue) return &.{};
        if (!self.panes.contains(req.pane_id)) {
            log.info("select of unknown pane id={}, dropping", .{req.pane_id});
            return &.{};
        }

        return self.queueSelect(req.pane_id) catch {
            log.warn("failed to queue select-pane", .{});
            return &.{};
        };
    }

    /// `select-pane`, preceded by `select-window` when the pane the user
    /// moved into is not in the window tmux is on, each only if needed.
    ///
    /// `select-pane` only moves the active pane *within its own window*
    /// (tmux `cmd-select-pane.c`), so without the window, focusing a pane
    /// in another window would leave tmux on the window it was already on
    /// and quietly disagree with the screen.
    ///
    /// What they ask for is taken as done the moment they are sent: the
    /// current window and the window's active pane are moved here, so
    /// every window list the GUI is sent while they are on their way
    /// already says where the user went. Left at what tmux last said, an
    /// unrelated update in that time (a rename, an alert, a layout) would
    /// send the GUI back to where the user came from, and its focus
    /// following that would select it in tmux again, undoing the switch.
    fn queueSelect(
        self: *Viewer,
        pane_id: usize,
    ) Allocator.Error![]const Action {
        const window = self.windowForPane(pane_id) orelse {
            log.info("select of pane id={} in no window, dropping", .{pane_id});
            return &.{};
        };

        const need_window = self.current_window_id != window.id or
            !window.active;
        const need_pane = window.active_pane_id != pane_id;

        var commands: [2]Command = undefined;
        var count: usize = 0;

        // The window first: selecting a pane in a window tmux is not on
        // is the same clamping problem as sizing a pane inside a window
        // that is too small.
        if (need_window) {
            commands[count] = .{ .select_window = window.id };
            count += 1;
            self.setCurrentWindow(window.id);
        }

        if (need_pane) {
            commands[count] = .{ .select_pane = .{
                .window_id = window.id,
                .pane_id = pane_id,
            } };
            count += 1;
            window.active_pane_id = pane_id;

            // `select-pane` without `-Z` unzooms its window (tmux's
            // `window_push_zoom`), and the GUI, moving to a pane the zoom
            // hides, unzooms too. Its panes report their unzoomed sizes
            // from here on; weighed against the zoom tmux is about to
            // drop, the one that was zoomed would size the whole window
            // down to its share of it.
            if (window.zoomed_pane_id) |zoomed| if (zoomed != pane_id) {
                window.zoomed_layout = null;
                window.zoomed_pane_id = null;
            };
        }

        if (count == 0) return &.{};
        return self.queueUserCommands(commands[0..count]);
    }

    /// Leave the session.
    ///
    /// `detach-client` with no target is this client, which is what the
    /// user meant: the session and everything running in it stays up,
    /// and tmux answers by ending control mode. Teardown is the same
    /// path a session that goes away any other way already takes, so
    /// there is nothing to unwind here.
    ///
    /// Before the session is up, or after we gave up on it, there is no
    /// queue to pair the reply with, so the command goes out as it is and
    /// its reply goes unread: `%exit` follows it either way. That is the
    /// way out of an attach that never finishes, which would otherwise
    /// leave only closing the host, and with it tmux's client.
    fn nextDetach(self: *Viewer) []const Action {
        if (self.state != .command_queue) {
            return self.singleAction(.{ .command = "detach-client\n" });
        }

        return self.queueUserCommand("detach-client\n", .{}) catch {
            log.warn("failed to queue detach-client", .{});
            return &.{};
        };
    }

    /// Ask tmux to split a pane.
    ///
    /// Targeted explicitly rather than relying on tmux's idea of the
    /// active pane, which is a different thing from the surface the user
    /// was looking at when they asked.
    fn nextSplit(self: *Viewer, split: Input.Split) []const Action {
        if (self.state != .command_queue) return &.{};

        if (!self.panes.contains(split.pane_id)) {
            log.info(
                "split of unknown pane id={}, dropping",
                .{split.pane_id},
            );
            return &.{};
        }

        // `-b` puts the new pane before the one split, which is what
        // left and up mean.
        return self.queueUserCommand("split-window {s} -t %{d}{f}\n", .{
            switch (split.direction) {
                .right => "-h",
                .left => "-h -b",
                .down => "-v",
                .up => "-v -b",
            },
            split.pane_id,
            self.startDirectory(
                if (split.inherit_working_directory) split.pane_id else null,
            ),
        }) catch {
            log.warn("failed to queue split for pane id={}", .{split.pane_id});
            return &.{};
        };
    }

    /// Ask tmux to close one or more windows.
    ///
    /// Each window is killed by id rather than with `kill-window -a`,
    /// because "other" and "to the right" are questions about the order
    /// the viewer holds, and tmux's own `-a` answers a different one: it
    /// kills everything but the target across the session regardless of
    /// position.
    fn nextKillWindows(
        self: *Viewer,
        req: Input.KillWindows,
    ) []const Action {
        if (self.state != .command_queue) return &.{};

        const target = self.windowForPane(req.pane_id) orelse {
            log.info(
                "close for pane id={} in no window, dropping",
                .{req.pane_id},
            );
            return &.{};
        };
        const target_id = target.id;

        const index: usize = for (self.windows.items, 0..) |w, i| {
            if (w.id == target_id) break i;
        } else return &.{};

        return self.queueKills(target_id, index, req.scope) catch |err| {
            log.warn("failed to queue window close err={}", .{err});
            return &.{};
        };
    }

    fn queueKills(
        self: *Viewer,
        target_id: usize,
        index: usize,
        scope: Input.KillWindows.Scope,
    ) Allocator.Error![]const Action {
        var commands: std.ArrayList(Command) = .empty;
        defer commands.deinit(self.alloc);
        errdefer for (commands.items) |c| c.deinit(self.alloc);

        for (self.windows.items, 0..) |w, i| {
            const wanted = switch (scope) {
                .this => w.id == target_id,
                .others => w.id != target_id,
                .right => i > index,
            };
            if (!wanted) continue;

            try commands.append(
                self.alloc,
                try self.userCommand("kill-window -t @{d}\n", .{w.id}),
            );
        }

        if (commands.items.len == 0) return &.{};

        // Ownership passes to the queue, success or not.
        const owned = commands.items;
        commands = .empty;
        return self.queueUserCommands(owned);
    }

    /// Ask tmux to kill a pane.
    fn nextKillPane(self: *Viewer, k: Input.KillPane) []const Action {
        if (self.state != .command_queue) return &.{};

        if (!self.panes.contains(k.pane_id)) {
            log.info("kill of unknown pane id={}, dropping", .{k.pane_id});
            return &.{};
        }

        return self.queueUserCommand("kill-pane -t %{d}\n", .{
            k.pane_id,
        }) catch {
            log.warn("failed to queue kill for pane id={}", .{k.pane_id});
            return &.{};
        };
    }

    /// Hide a window from the GUI, or show it again.
    ///
    /// Set on the window in tmux and then read back, rather than changed
    /// here first: the window list that answers is what carries it to the
    /// GUI, through the same comparison as any other list (`syncHidden`).
    /// Changed here first, a list already on its way when the user asked
    /// would land after the change and quietly undo it.
    fn nextHideWindow(self: *Viewer, req: Input.HideWindow) []const Action {
        if (self.state != .command_queue) return &.{};

        for (self.windows.items) |w| {
            if (w.id == req.window_id) break;
        } else {
            log.info("hide of unknown window id={}, dropping", .{req.window_id});
            return &.{};
        }

        // `-u` unsets rather than setting it to 0: a window nobody ever
        // hid should look the same in tmux as one that was shown again.
        const set = (if (req.hidden)
            self.userCommand("set-option -w -t @{d} @ghostty-hidden 1\n", .{req.window_id})
        else
            self.userCommand("set-option -w -u -t @{d} @ghostty-hidden\n", .{req.window_id})) catch {
            log.warn("failed to queue hiding window id={}", .{req.window_id});
            return &.{};
        };

        return self.queueUserCommands(&.{ set, .list_windows }) catch {
            log.warn("failed to queue hiding window id={}", .{req.window_id});
            return &.{};
        };
    }

    /// Move to another session.
    ///
    /// tmux answers with `%session-changed`, which starts this viewer
    /// over for that session (`sessionChanged`), as when anything else
    /// moves this client. Asking for the session we are already on is
    /// harmless: tmux announces it the same way, and the session's
    /// windows are read again.
    fn nextSwitchSession(self: *Viewer, req: Input.SwitchSession) []const Action {
        if (self.state != .command_queue) return &.{};

        // Quoted: unquoted, tmux would read `$3` as an environment
        // variable.
        return self.queueUserCommand("switch-client -t '${d}'\n", .{
            req.session_id,
        }) catch {
            log.warn("failed to queue switch to session id={}", .{req.session_id});
            return &.{};
        };
    }

    /// Read the server's sessions, and keep reading them as they change.
    fn nextListSessions(self: *Viewer) []const Action {
        if (self.state != .command_queue) return &.{};
        self.sessions_wanted = true;

        return self.queueUserCommands(&.{.list_sessions}) catch {
            log.warn("failed to queue list-sessions", .{});
            return &.{};
        };
    }

    /// Read the session list again, if anything wants it.
    fn sessionsChanged(self: *Viewer) Allocator.Error!void {
        if (!self.sessions_wanted) return;
        try self.queueCommands(&.{.list_sessions});
    }

    /// The longest paste buffer we mirror, in bytes.
    ///
    /// A buffer arrives inside a `%begin` block, and a block line longer
    /// than `control.Parser.max_line_bytes` (1 MiB) ends the session. A
    /// buffer with no newline is one line, and every control byte in it
    /// is written as four (see `Command.paste_buffer`), so this leaves
    /// room for the worst case. tmux is asked to leave out anything
    /// longer rather than send it.
    pub const max_mirrored_buffer_bytes = 192 * 1024;

    /// One of tmux's paste buffers changed: read it, for the clipboard.
    fn pasteBufferChanged(self: *Viewer, name: []const u8) Allocator.Error!void {
        if (!self.mirror_paste_buffers) return;

        // Our own pastes go through a buffer, and so do every other
        // ghostty's. Those hold something being pasted, which came from
        // a clipboard in the first place.
        if (std.mem.startsWith(u8, name, paste_buffer_prefix)) return;

        // The name goes into a format inside a quoted argument (see
        // `Command.paste_buffer`). tmux's own names (`buffer0`) and any
        // sensible one fit in this; anything else is not worth the
        // escaping it would take.
        for (name) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => {
                log.info("not mirroring a paste buffer with an unusual name", .{});
                return;
            },
        };
        if (name.len == 0) return;

        const owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned);
        try self.queueCommands(&.{.{ .paste_buffer = owned }});
    }

    /// The paste buffer asked for by `pasteBufferChanged`, as
    /// `Command.paste_buffer` frames and escapes it.
    fn receivedPasteBuffer(
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) Allocator.Error!void {
        // Nothing at all: the buffer was deleted before we asked, or is
        // too long to mirror and tmux left it out.
        if (content.len < 2 or content[0] != '>' or content[content.len - 1] != '<') {
            log.debug("paste buffer gone or too long, not mirrored", .{});
            return;
        }

        const escaped = content[1 .. content.len - 1];

        // Empty between the markers is also a tmux too old to have
        // `buffer_full`, which expands to nothing. Either way there is
        // nothing to put on the clipboard, and putting nothing there
        // would wipe what the user had.
        if (escaped.len == 0) return;

        // A newline in the buffer cannot be escaped (see
        // `Command.paste_buffer`), so it crosses the pty tmux -CC writes
        // to as it is, and that pty's output processing, which tmux
        // leaves on, makes it a CRLF. One CR is taken off each CRLF to
        // undo that. A CR of the buffer's own before a newline survives,
        // as the second of two; only through a pty with output processing
        // off, which we have not seen, would it be lost.
        const buf = try arena_alloc.alloc(u8, escaped.len);
        var len: usize = 0;
        var i: usize = 0;
        while (i < escaped.len) : (i += 1) {
            if (escaped[i] == '\r' and
                i + 1 < escaped.len and escaped[i + 1] == '\n') continue;
            buf[len] = escaped[i];
            len += 1;
        }

        try actions.append(arena_alloc, .{
            .paste_buffer = control.unescape(buf[0..len], buf[0..len]),
        });
    }

    fn receivedSessions(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        var sessions: std.ArrayList(Session) = .empty;
        defer sessions.deinit(self.alloc);
        errdefer for (sessions.items) |s| self.alloc.free(s.name);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_sessions.Struct(),
                line,
                Format.list_sessions.delim,
            ) catch |err| {
                log.info("failed to parse list-sessions line: {s}", .{line});
                return err;
            };

            const name = try self.alloc.dupe(u8, data.session_name);
            errdefer self.alloc.free(name);
            try sessions.append(self.alloc, .{
                .id = data.session_id,
                .name = name,
                .windows = data.session_windows,
                .attached = data.session_attached,
            });
        }

        // Swapped rather than copied, so the old list and its names are
        // what `sessions` frees on the way out.
        self.clearSessions();
        std.mem.swap(std.ArrayList(Session), &self.sessions, &sessions);

        // The session list is part of what the window list announces.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
    }

    /// Whether `pane_id` is in a window of `windows` that is hidden.
    fn paneHiddenIn(windows: []const Window, pane_id: usize) bool {
        for (windows) |w| {
            if (w.hidden and layoutContainsPane(w.layout, pane_id)) return true;
        }
        return false;
    }

    /// Whether `pane_id` is in a hidden window, and so should not be
    /// displayed. See `Window.hidden`.
    pub fn paneHidden(self: *const Viewer, pane_id: usize) bool {
        return paneHiddenIn(self.windows.items, pane_id);
    }

    /// Act on the windows a new window list hides or shows, compared to
    /// the list we have. Called before the new list replaces ours.
    ///
    /// A window going hidden has its panes' displays told they are gone:
    /// the GUI drops the tab, and nothing goes on buffering output for a
    /// display that will never take it. The panes themselves stay, since
    /// tmux still has them.
    ///
    /// A window shown again has its panes read from scratch, exactly as
    /// on attach. Nothing was mirrored while it was hidden, and its
    /// displays are new and empty; the captures are queued before the
    /// window list that tells the GUI to build them goes out, so their
    /// replies reach the displays (see `attachPane`), lazily if history
    /// is read lazily (`queuePaneReads`). Panes new to us are left to
    /// `syncLayouts`, which reads every new pane.
    fn syncHidden(self: *Viewer, windows: []const Window) !void {
        var reread: std.ArrayList(usize) = .empty;
        defer reread.deinit(self.alloc);
        for (windows) |new| {
            const old = for (self.windows.items) |w| {
                if (w.id == new.id) break w;
            } else continue;
            if (old.hidden == new.hidden) continue;

            log.info("tmux window id={} hidden={}", .{ new.id, new.hidden });
            if (new.hidden) {
                self.detachLayout(new.layout);
            } else {
                try self.collectLayoutPanes(new.layout, &reread);
            }
        }
        if (reread.items.len == 0) return;
        try self.queuePaneReads(&self.panes, reread.items);
        try self.queueCommands(&.{.pane_state});
    }

    /// Stop mirroring every pane in a layout.
    fn detachLayout(self: *Viewer, node: Layout) void {
        switch (node.content) {
            .pane => |id| self.detachPane(id),
            .horizontal, .vertical => |children| for (children) |child| {
                self.detachLayout(child);
            },
        }
    }

    /// Queue captures for every pane in a layout that we already have.    /// Every pane in a layout that we already have, for reading again.
    fn collectLayoutPanes(
        self: *Viewer,
        node: Layout,
        ids: *std.ArrayList(usize),
    ) Allocator.Error!void {
        switch (node.content) {
            .pane => |id| if (self.panes.contains(id)) {
                try ids.append(self.alloc, id);
            },
            .horizontal, .vertical => |children| for (children) |child| {
                try self.collectLayoutPanes(child, ids);
            },
        }
    }

    /// Ask tmux to swap a pane with another pane of its window.
    ///
    /// Previous and next are tmux's own `-U` and `-D`, which go by tmux's
    /// pane order and wrap around, exactly as its `{` and `}` bindings
    /// do. A direction is resolved here, from the layout, because tmux's
    /// `{left-of}` and friends are relative to the *active* pane rather
    /// than to a target we can name.
    ///
    /// Either way the pane asked about is tmux's `-t` and the other one
    /// its `-s`, and there is no `-d`: tmux then makes the target active
    /// in its new place, so focus goes with the pane the user moved, as
    /// it does when Ghostty moves a split.
    fn nextSwapPane(self: *Viewer, req: Input.SwapPane) []const Action {
        if (self.state != .command_queue) return &.{};

        const window = self.windowForPane(req.pane_id) orelse {
            log.info("swap of pane id={} in no window", .{req.pane_id});
            return &.{};
        };

        const result = switch (req.target) {
            .previous, .next => self.queueUserCommand(
                "swap-pane {s} -t %{d}\n",
                .{
                    if (req.target == .previous) "-U" else "-D",
                    req.pane_id,
                },
            ),

            .left, .right, .up, .down => result: {
                const other = paneBeside(
                    window.layout,
                    req.pane_id,
                    req.target,
                ) orelse return &.{};
                break :result self.queueUserCommand(
                    "swap-pane -s %{d} -t %{d}\n",
                    .{ other, req.pane_id },
                );
            },
        };

        return result catch {
            log.warn("failed to queue swap-pane", .{});
            return &.{};
        };
    }

    /// The pane that shares an edge with `pane_id` on the given side of
    /// the layout, or null at the edge of the window.
    ///
    /// Where several do, the one sharing the most of it, and of those the
    /// topmost or leftmost: the same answer for the same layout every
    /// time, which matters more here than matching tmux's own pick (its
    /// most recently used), because it is the pane the user can see.
    fn paneBeside(
        root: Layout,
        pane_id: usize,
        side: sinkpkg.SwapTarget,
    ) ?usize {
        const me = layoutPane(root, pane_id) orelse return null;

        const Best = struct { id: usize, overlap: usize, start: usize };
        var best: ?Best = null;

        var leaves: LeafIterator = .{ .stack = undefined };
        leaves.push(root);
        while (leaves.next()) |other| {
            if (other.content.pane == pane_id) continue;

            // A divider is one cell wide, so a neighbour's edge is one
            // past ours.
            const touches = switch (side) {
                .left => other.x + other.width + 1 == me.x,
                .right => me.x + me.width + 1 == other.x,
                .up => other.y + other.height + 1 == me.y,
                .down => me.y + me.height + 1 == other.y,
                .previous, .next => unreachable,
            };
            if (!touches) continue;

            const horizontal = side == .left or side == .right;
            const a0 = if (horizontal) me.y else me.x;
            const a1 = a0 + if (horizontal) me.height else me.width;
            const b0 = if (horizontal) other.y else other.x;
            const b1 = b0 + if (horizontal) other.height else other.width;
            const overlap = @min(a1, b1) -| @max(a0, b0);
            if (overlap == 0) continue;

            const candidate: Best = .{
                .id = other.content.pane,
                .overlap = overlap,
                .start = b0,
            };
            if (best) |b| {
                if (overlap < b.overlap) continue;
                if (overlap == b.overlap and b0 >= b.start) continue;
            }
            best = candidate;
        }

        return if (best) |b| b.id else null;
    }

    /// The layout node of a pane, for its position and size.
    fn layoutPane(node: Layout, pane_id: usize) ?Layout {
        return switch (node.content) {
            .pane => |id| if (id == pane_id) node else null,
            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutPane(child, pane_id)) |found| break found;
            } else null,
        };
    }

    /// Walks the panes of a layout without allocating. tmux layouts are
    /// a handful of levels deep; one deeper than the stack is skipped
    /// rather than failing, and is merely never offered as a neighbour.
    const LeafIterator = struct {
        stack: [32]Layout,
        len: usize = 0,

        fn push(self: *LeafIterator, node: Layout) void {
            if (self.len == self.stack.len) return;
            self.stack[self.len] = node;
            self.len += 1;
        }

        fn next(self: *LeafIterator) ?Layout {
            while (self.len > 0) {
                self.len -= 1;
                const node = self.stack[self.len];
                switch (node.content) {
                    .pane => return node,
                    .horizontal, .vertical => |children| for (children) |child| {
                        self.push(child);
                    },
                }
            }
            return null;
        }
    };

    /// Ask tmux to rotate the panes of a pane's window.
    fn nextRotateWindow(self: *Viewer, req: Input.RotateWindow) []const Action {
        if (self.state != .command_queue) return &.{};

        const window = self.windowForPane(req.pane_id) orelse {
            log.info("rotate for pane id={} in no window", .{req.pane_id});
            return &.{};
        };

        return self.queueUserCommand("rotate-window {s} -t @{d}\n", .{
            switch (req.direction) {
                .previous => "-U",
                .next => "-D",
            },
            window.id,
        }) catch {
            log.warn("failed to queue rotate-window", .{});
            return &.{};
        };
    }

    /// Ask tmux to take a pane out into a window of its own.
    ///
    /// No `-d`: tmux makes the new window current, and the GUI follows it
    /// there, as it would follow a new tab. A pane alone in its window
    /// has nothing to break from, and tmux says so.
    fn nextBreakPane(self: *Viewer, req: Input.BreakPane) []const Action {
        if (self.state != .command_queue) return &.{};
        if (!self.panes.contains(req.pane_id)) {
            log.info("break of unknown pane id={}, dropping", .{req.pane_id});
            return &.{};
        }

        return self.queueUserCommand("break-pane -s %{d}\n", .{
            req.pane_id,
        }) catch {
            log.warn("failed to queue break-pane", .{});
            return &.{};
        };
    }

    /// Ask tmux to move a pane into the window before or after its own.
    ///
    /// The neighbour comes from our ordered window list, as for moving a
    /// window, and there is none past either end. The pane goes to the
    /// right of that window's active pane (`-h`), which is where Ghostty
    /// puts a new split by default. No `-d`: tmux goes to that window and
    /// makes the pane active there, so the user goes with it.
    fn nextJoinPane(self: *Viewer, req: Input.JoinPane) []const Action {
        if (self.state != .command_queue) return &.{};

        const window = self.windowForPane(req.pane_id) orelse {
            log.info("join for pane id={} in no window", .{req.pane_id});
            return &.{};
        };

        const from: usize = for (self.windows.items, 0..) |w, i| {
            if (w.id == window.id) break i;
        } else return &.{};

        const to: usize = switch (req.window) {
            .previous => if (from == 0) return &.{} else from - 1,
            .next => if (from + 1 >= self.windows.items.len)
                return &.{}
            else
                from + 1,
        };

        return self.queueUserCommand("join-pane -h -s %{d} -t @{d}\n", .{
            req.pane_id,
            self.windows.items[to].id,
        }) catch {
            log.warn("failed to queue join-pane", .{});
            return &.{};
        };
    }

    /// Ask tmux to move a pane beside another, in whichever window that
    /// one is in: `join-pane`, which within one window is a move.
    ///
    /// This is Ghostty's split drag and drop, so the sides are the drop
    /// zones: `-b` puts the pane before the target, as for a split.
    fn nextMovePane(self: *Viewer, req: Input.MovePane) []const Action {
        if (self.state != .command_queue) return &.{};
        if (req.pane_id == req.target_pane_id) return &.{};
        if (!self.panes.contains(req.pane_id) or
            !self.panes.contains(req.target_pane_id))
        {
            log.info(
                "move of pane id={} to pane id={}, one unknown, dropping",
                .{ req.pane_id, req.target_pane_id },
            );
            return &.{};
        }

        return self.queueUserCommand("join-pane {s} -s %{d} -t %{d}\n", .{
            switch (req.direction) {
                .right => "-h",
                .left => "-h -b",
                .down => "-v",
                .up => "-v -b",
            },
            req.pane_id,
            req.target_pane_id,
        }) catch {
            log.warn("failed to queue join-pane", .{});
            return &.{};
        };
    }

    /// Run a command line the user typed, and tell them what came of it.
    ///
    /// The line is tmux's to parse, so it can be anything tmux's own
    /// command prompt takes, several commands joined with `;` included.
    /// That is the difficulty: tmux answers each command of a line with a
    /// block of its own, and a command such as `if-shell` or `source-file`
    /// runs more, each with a block too, so there is no knowing how many
    /// replies a line will get. Pairing replies with commands by order --
    /// which everything else here depends on -- would be lost after the
    /// first.
    ///
    /// So the line is followed by a command whose answer we can recognise:
    /// `display-message -p` of `command_marker`. Every block until that
    /// one belongs to the line, however many there are; see
    /// `receivedCommandOutput`. tmux stops a line at its first failing
    /// command, but the marker is a line of its own and always runs.
    ///
    /// Control characters are dropped, as for a window name: a newline
    /// would end the line early, and the rest would run as another one
    /// with nothing waiting for its answers.
    fn nextCommandLine(self: *Viewer, req: Input.CommandLine) []const Action {
        if (self.state != .command_queue) return &.{};

        const prompt = Prompt.create(
            self.alloc,
            req.text,
            &self.command_marker,
        ) catch {
            log.warn("failed to queue a command line", .{});
            return &.{};
        };
        if (prompt.line.len == 0) {
            prompt.destroy(self.alloc);
            return &.{};
        }

        return self.queueUserCommands(&.{.{ .prompt = prompt }}) catch {
            log.warn("failed to queue a command line", .{});
            return &.{};
        };
    }

    /// Queue a command for tmux, returning the action that sends it.
    ///
    /// Everything the caller can ask tmux to do goes through here; tmux
    /// answers each with a `%begin`/`%end` block that
    /// `receivedCommandOutput` pairs with it by order.
    fn queueUserCommand(
        self: *Viewer,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error![]const Action {
        // queueUserCommands takes ownership whether it succeeds or not.
        return self.queueUserCommands(&.{try self.userCommand(fmt, args)});
    }

    /// Build a user command from a format string. The caller owns it
    /// until it is handed to `queueUserCommands`.
    fn userCommand(
        self: *Viewer,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!Command {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();
        builder.writer.print(fmt, args) catch return error.OutOfMemory;
        return .{ .user = try builder.toOwnedSlice() };
    }

    /// Like `userCommand`, for a command nobody asked for: see
    /// `Command.ours`.
    fn ourCommand(
        self: *Viewer,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!Command {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();
        builder.writer.print(fmt, args) catch return error.OutOfMemory;
        return .{ .ours = try builder.toOwnedSlice() };
    }

    /// Queue commands and return the actions that send them. Ownership
    /// of `commands` passes to the queue whether this succeeds or not.
    fn queueUserCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state == .command_queue);
        assert(commands.len > 0);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);

        self.queueCommands(commands) catch |err| {
            for (commands) |c| c.deinit(self.alloc);
            return err;
        };

        var actions: std.ArrayList(Action) = .empty;
        try self.flushCommands(arena.allocator(), &actions);
        return actions.items;
    }

    /// Send bytes to a pane as tmux `send-keys`.
    ///
    /// This goes through the command queue like any other command, so its
    /// reply is paired with it by order; `receivedCommandOutput` discards
    /// it unless it is an error. It is sent at once, not after whatever is
    /// already in flight is answered: see `command_queue`.
    fn nextWrite(
        self: *Viewer,
        w: Input.Write,
    ) []const Action {
        // We can only send input once we've reached steady state. Before
        // that we're still replaying startup commands and don't know the
        // pane set.
        if (self.state != .command_queue) {
            log.info(
                "write to pane id={} while not ready, dropping",
                .{w.pane_id},
            );
            return &.{};
        }

        // Drop writes to panes we don't know about rather than letting
        // tmux error on an unknown target.
        if (!self.panes.contains(w.pane_id)) {
            log.info("write to unknown pane id={}, dropping", .{w.pane_id});
            return &.{};
        }

        // Nothing to send. Avoid a `send-keys` with no keys, which tmux
        // would interpret as "send the key this command is bound to".
        if (w.data.len == 0) return &.{};

        self.reclaimWindowSize(w.pane_id);

        return self.queueWrite(w) catch {
            log.warn(
                "failed to queue write for pane id={}, dropping",
                .{w.pane_id},
            );
            return &.{};
        };
    }

    /// The `select-layout` laying out a window found on attach as
    /// `attach_layout` says, once its size and its saved layout are both
    /// known, or null if there is nothing (more) to do.
    ///
    /// Made for the size we last asked for, which is the size tmux is
    /// about to have the window at: a layout of another size would be
    /// resized by tmux, its own way, which is what this is to avoid.
    fn arrangeCommand(self: *Viewer, window: *Window) Allocator.Error!?Command {
        if (!window.arrange_pending or !self.saved_layouts_known) return null;
        const want = window.last_size_request orelse return null;

        window.arrange_pending = false;
        const saved_str = window.saved_layout;
        window.saved_layout = null;
        defer if (saved_str) |v| self.alloc.free(v);

        // A zoom is tmux's to keep, and what is behind it is not shown.
        if (window.zoomed_layout != null) return null;
        if (window.layout.content == .pane) return null;

        var arena: ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const restored: ?Layout = restored: {
            if (self.attach_layout != .restore) break :restored null;
            const str = saved_str orelse break :restored null;
            const saved = Layout.parseWithChecksum(alloc, str) catch break :restored null;
            if (!saved.sameShape(window.layout)) break :restored null;
            break :restored try saved.arrange(alloc, want.cols, want.rows, .proportional);
        };
        const arranged = restored orelse
            try window.layout.arrange(alloc, want.cols, want.rows, .equal) orelse
            return null;

        return try self.ourCommand("select-layout -t @{d} '{s}'\n", .{
            window.id,
            try arranged.writeWithChecksum(alloc),
        });
    }

    /// Lay out the windows found on attach that are waiting only for
    /// their saved layouts, now that those are known. Windows whose size
    /// we have not asked for yet are laid out when we do.
    fn arrangeWindows(self: *Viewer) Allocator.Error!void {
        for (self.windows.items) |*window| {
            const command = try self.arrangeCommand(window) orelse continue;
            errdefer command.deinit(self.alloc);
            try self.queueCommands(&.{command});
        }
    }

    /// Save `layout_str`, the window's layout as tmux has just sent it,
    /// in the window, if it is a layout at the size we asked for.
    /// See `Window.saved_layout`.
    fn saveLayout(
        self: *Viewer,
        window: *Window,
        layout_str: []const u8,
    ) Allocator.Error!void {
        if (self.attach_layout != .restore) return;

        // Not before it is ours: the layout attaching found is the one
        // being put right.
        if (window.arrange_pending) return;
        if (window.zoomed_layout != null) return;
        const want = window.last_size_request orelse return;
        if (window.layout.width != want.cols or
            window.layout.height != want.rows) return;

        const hash = std.hash.Wyhash.hash(0, layout_str);
        if (window.saved_hash == hash) return;

        // A layout is digits, `x`, commas and brackets: nothing quoting
        // could trip over.
        for (layout_str) |c| switch (c) {
            '0'...'9', 'a'...'f', 'x', ',', '{', '}', '[', ']' => {},
            else => return,
        };

        const command = try self.ourCommand(
            "set-option -w -t @{d} @ghostty-layout '{s}'\n",
            .{ window.id, layout_str },
        );
        errdefer command.deinit(self.alloc);
        try self.queueCommands(&.{command});
        window.saved_hash = hash;
    }

    fn receivedSavedLayouts(self: *Viewer, content: []const u8) Allocator.Error!void {
        self.saved_layouts_known = true;

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            const sep = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const layout = std.mem.trim(u8, line[sep + 1 ..], " ");
            if (layout.len == 0) continue;
            const window_id = output.Variable.parse(
                .window_id,
                line[0..sep],
            ) catch continue;
            for (self.windows.items) |*window| {
                if (window.id != window_id or !window.arrange_pending) continue;
                if (window.saved_layout) |v| self.alloc.free(v);
                window.saved_layout = try self.alloc.dupe(u8, layout);
                window.saved_hash = std.hash.Wyhash.hash(0, layout);
            }
        }

        try self.arrangeWindows();
    }

    /// Ask again for the size we last asked for a pane's window, if
    /// another client has taken the window over since. Queued, not sent:
    /// the input that called for it sends it, ahead of itself.
    ///
    /// With another client attached, tmux sizes a window for one of them
    /// (`window-size`, `latest` by default: the client that last typed
    /// into it). Our `send-keys` do not count as typing, so once the
    /// other client has typed, the window stays at its size, and our
    /// panes at a size their surfaces never asked for, until the native
    /// window happens to be resized. Asking again, as the user types
    /// here, is what typing in a normal client does: the window follows
    /// whoever is using it. Once per takeover, so a window tmux keeps at
    /// another size on purpose (`window-size smallest`) costs one
    /// command, not one per keystroke.
    fn reclaimWindowSize(self: *Viewer, pane_id: usize) void {
        // Older servers are sized with `resize-window`, which pins the
        // size for every client; nothing can take it over.
        if (!self.tmuxVersionAtLeast(3, 4)) return;

        const window = self.windowForPane(pane_id) orelse return;
        if (!window.size_taken) return;
        const want = window.last_size_request orelse return;
        window.size_taken = false;

        const command = self.userCommand(
            "refresh-client -C @{d}:{d}x{d}\n",
            .{ window.id, want.cols, want.rows },
        ) catch {
            log.warn("failed to queue reclaiming window id={}", .{window.id});
            return;
        };
        self.queueCommands(&.{command}) catch {
            command.deinit(self.alloc);
            log.warn("failed to queue reclaiming window id={}", .{window.id});
        };
    }

    /// The most input bytes one `send-keys` carries.
    ///
    /// tmux parses a command line with a yacc parser whose stack grows
    /// with every argument, and `send-keys -H` takes one argument per
    /// byte. tmux 3.6 fails a command of about ten thousand arguments
    /// with "parse error: yacc stack overflow" and sends none of it, so a
    /// large paste has to be split. This leaves a wide margin under that
    /// while keeping the number of commands for a big paste small.
    pub const max_send_keys_bytes = 2048;

    fn queueWrite(
        self: *Viewer,
        w: Input.Write,
    ) Allocator.Error![]const Action {
        // One command per chunk, queued together so that nothing can be
        // queued in between: tmux runs commands in the order it reads
        // them, so the pane receives the chunks in order and whole. A
        // bracketed paste's markers are bytes like any other, so a paste
        // split across commands is still one paste to the program.
        const count = std.math.divCeil(
            usize,
            w.data.len,
            max_send_keys_bytes,
        ) catch unreachable;
        const commands = try self.alloc.alloc(Command, count);
        defer self.alloc.free(commands);

        {
            var built: usize = 0;
            errdefer for (commands[0..built]) |c| c.deinit(self.alloc);
            var rest = w.data;
            while (rest.len > 0) : (built += 1) {
                const chunk = rest[0..@min(rest.len, max_send_keys_bytes)];
                rest = rest[chunk.len..];
                commands[built] = try self.sendKeysCommand(w.pane_id, chunk);
            }
            assert(built == count);
        }

        // Owns the commands from here, whether it succeeds or not.
        return self.queueUserCommands(commands);
    }

    /// Paste text into a pane through tmux's own paste buffers.
    ///
    /// A paste is not sent as keys because of bracketed paste. Whether
    /// to frame it depends on whether the pane's program asked for that
    /// (mode 2004), and we cannot know: tmux has no format for it, so a
    /// program that turned it on before we attached -- an editor started
    /// once, unlike a shell that asks again at every prompt -- looks to
    /// us as if it never had. An unframed paste into an editor that
    /// wanted a framed one is typed text, and autoindent mangles it.
    ///
    /// tmux does know. `paste-buffer -p` frames the paste if and only if
    /// the pane's program asked for it, so the text goes into a buffer
    /// and tmux pastes it from there:
    ///
    ///   - `set-buffer` the text, in chunks, the first replacing the
    ///     buffer and the rest appending with `-a`;
    ///   - `paste-buffer -p -r -d`: framed as the program asked, the
    ///     text as it is (`-r`, no newline translation: the caller has
    ///     already done that), and the buffer deleted afterwards.
    ///
    /// All of it is queued together, so tmux runs it in order with the
    /// keys typed before and after it.
    fn nextPaste(
        self: *Viewer,
        p: Input.Write,
    ) []const Action {
        if (self.state != .command_queue) {
            log.info(
                "paste to pane id={} while not ready, dropping",
                .{p.pane_id},
            );
            return &.{};
        }

        if (!self.panes.contains(p.pane_id)) {
            log.info("paste to unknown pane id={}, dropping", .{p.pane_id});
            return &.{};
        }

        if (p.data.len == 0) return &.{};

        self.reclaimWindowSize(p.pane_id);

        return self.queuePaste(p) catch {
            log.warn(
                "failed to queue paste for pane id={}, dropping",
                .{p.pane_id},
            );
            return &.{};
        };
    }

    /// The most paste bytes one `set-buffer` carries.
    ///
    /// tmux has no limit on a control mode line and the text is a single
    /// argument, so the yacc stack that bounds `send-keys` does not apply
    /// (`max_send_keys_bytes`). This only keeps any one command, which
    /// is up to four times this once escaped, a reasonable size.
    pub const max_set_buffer_bytes = 16 * 1024;

    fn queuePaste(
        self: *Viewer,
        p: Input.Write,
    ) Allocator.Error![]const Action {
        const chunks = std.math.divCeil(
            usize,
            p.data.len,
            max_set_buffer_bytes,
        ) catch unreachable;
        const commands = try self.alloc.alloc(Command, chunks + 1);
        defer self.alloc.free(commands);

        {
            var built: usize = 0;
            errdefer for (commands[0..built]) |c| c.deinit(self.alloc);
            var rest = p.data;
            while (rest.len > 0) : (built += 1) {
                const chunk = rest[0..@min(rest.len, max_set_buffer_bytes)];
                rest = rest[chunk.len..];
                commands[built] = try self.setBufferCommand(
                    chunk,
                    built > 0,
                );
            }
            assert(built == chunks);

            commands[built] = try self.userCommand(
                "paste-buffer -p -r -d -b {s} -t %{d}\n",
                .{ &self.paste_buffer, p.pane_id },
            );
        }

        // Owns the commands from here, whether it succeeds or not.
        return self.queueUserCommands(commands);
    }

    /// `set-buffer` of arbitrary bytes into our paste buffer.
    ///
    /// The bytes go in a double-quoted string, where tmux's parser turns
    /// a backslash and three octal digits into that byte. Everything but
    /// printable ASCII is written that way, and of printable ASCII the
    /// three characters that mean something inside double quotes: `"`
    /// and `\`, and `$`, which would expand an environment variable.
    /// That covers the newline, which would otherwise end the command
    /// (tmux reads control mode a line at a time), and bytes above
    /// ASCII, which tmux's lexer will not take raw if they are not valid
    /// UTF-8 -- and a chunk boundary can split a valid sequence. `#` is
    /// safe: `set-buffer` does not expand formats.
    fn setBufferCommand(
        self: *Viewer,
        data: []const u8,
        append: bool,
    ) Allocator.Error!Command {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();
        writeSetBuffer(
            &builder.writer,
            &self.paste_buffer,
            data,
            append,
        ) catch return error.OutOfMemory;
        return .{ .user = try builder.toOwnedSlice() };
    }

    fn writeSetBuffer(
        writer: *std.Io.Writer,
        name: []const u8,
        data: []const u8,
        append: bool,
    ) std.Io.Writer.Error!void {
        // `--` because the text can start with a `-`, and the parser has
        // removed the quotes by the time the flags are read.
        try writer.print("set-buffer{s} -b {s} -- \"", .{
            if (append) " -a" else "",
            name,
        });
        for (data) |c| {
            const literal = c >= ' ' and c <= '~' and
                c != '"' and c != '\\' and c != '$';
            if (literal)
                try writer.writeByte(c)
            else
                try writer.print("\\{o:0>3}", .{c});
        }
        try writer.writeAll("\"\n");
    }

    /// `send-keys -H` takes each key as a hexadecimal number, so we can
    /// pass arbitrary encoded input through byte-for-byte without tmux
    /// attempting to interpret any of it as a key name.
    fn sendKeysCommand(
        self: *Viewer,
        pane_id: usize,
        data: []const u8,
    ) Allocator.Error!Command {
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer builder.deinit();
        builder.writer.print("send-keys -H -t %{d}", .{pane_id}) catch
            return error.OutOfMemory;
        for (data) |byte| builder.writer.print(" {x:0>2}", .{byte}) catch
            return error.OutOfMemory;
        builder.writer.writeByte('\n') catch return error.OutOfMemory;
        return .{ .user = try builder.toOwnedSlice() };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => |reason| return self.exited(reason),

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            inline .block_end, .block_err => |content, tag| {
                self.state = .startup_session;
                return self.startupNotices(
                    content,
                    tag == .block_err,
                ) catch |err| {
                    log.warn("failed to report startup notices err={}", .{err});
                    return &.{};
                };
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return if (notificationNotice(n)) |notice|
                self.singleAction(.{ .notice = notice })
            else
                &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => |reason| return self.exited(reason),

            .session_changed => |info| {
                self.session_id = info.id;
                self.setSessionName(info.name) catch {
                    log.warn("failed to record the session name, detaching", .{});
                    return self.abandon();
                };

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                var actions: std.ArrayList(Action) = .empty;
                self.enterCommandQueue(
                    arena.allocator(),
                    &actions,
                    &.{ .tmux_version, .list_windows },
                ) catch {
                    log.warn("failed to queue command, detaching", .{});
                    return self.abandon();
                };

                // The session, before any of its windows: the GUI shows
                // the host as attached, with its way to detach, from
                // here on rather than once the window list is in. If
                // that never comes, detaching is still on offer.
                actions.append(
                    arena.allocator(),
                    .{ .windows = self.windows.items },
                ) catch {
                    log.warn("failed to announce the session, detaching", .{});
                    return self.abandon();
                };
                return actions.items;
            },

            else => return if (notificationNotice(n)) |notice|
                self.singleAction(.{ .notice = notice })
            else
                &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => |reason| return self.exited(reason),
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        switch (n) {
            .enter => unreachable,
            .exit => |reason| return self.exited(reason),

            inline .block_end,
            .block_err,
            => |content, tag| {
                self.receivedCommandOutput(
                    &actions,
                    content,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, detaching", .{});
                    return self.abandon();
                };
            },

            .output => |out| self.receivedOutput(
                out.pane_id,
                out.data,
            ) catch |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                    info.name,
                ) catch {
                    log.warn("failed to handle session change, detaching", .{});
                    return self.abandon();
                };
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
                info.raw_flags,
                info.visible_layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, detaching", .{});
                return self.abandon();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, detaching", .{});
                return self.abandon();
            },

            // tmux stopped sending us a pane's output. Ask for it back
            // and re-read the pane, since what it discarded meanwhile is
            // gone for good.
            .pause => |info| self.pauseRecover(info.pane_id) catch {
                log.warn("failed to resume a paused pane, detaching", .{});
                return self.abandon();
            },

            // tmux acknowledging the resume we asked for above. The
            // capture commands queued alongside it do the rest.
            .@"continue" => |info| log.info(
                "tmux resumed pane id={}",
                .{info.pane_id},
            ),

            // A window left this session, by being killed, by its last
            // pane exiting, or by being moved elsewhere.
            .window_close => |info| self.windowClose(info.id) catch {
                log.warn("failed to handle window close, detaching", .{});
                return self.abandon();
            },

            // A session was renamed. tmux tells every control client
            // about every session, so most of these are not ours.
            .session_renamed => |info| self.sessionRenamed(
                &actions,
                info.id,
                info.name,
            ) catch {
                log.warn("failed to record a session rename", .{});
            },

            // tmux moved a window's active pane, and the GUI follows.
            .window_pane_changed => |info| self.windowPaneChanged(
                &actions,
                info.window_id,
                info.pane_id,
            ) catch {
                log.warn("failed to handle active pane change", .{});
            },

            // tmux moved to another window, which is the one thing here
            // the GUI has to follow: the user asked for it in another
            // client, or a script did, and the window they mean is not
            // the one on screen.
            .session_window_changed => |info| self.sessionWindowChanged(
                &actions,
                info.session_id,
                info.window_id,
            ) catch {
                log.warn("failed to handle window change", .{});
            },

            // A session was created or destroyed. If it was our own we
            // will get an exit notification very soon. Otherwise it only
            // matters to the session list, if anything is keeping one.
            .sessions_changed => self.sessionsChanged() catch {
                log.warn("failed to queue list-sessions", .{});
            },

            // Update the name in place rather than re-listing: a rename
            // changes nothing else, and a round trip per keystroke of
            // someone's rename prompt would be absurd. The GUI still
            // hears of it, through the window list it already diffs.
            .window_renamed => |info| self.windowRenamed(
                &actions,
                info.id,
                info.name,
            ) catch {
                log.warn("failed to record a window rename", .{});
            },

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            // The session list counts attached clients, though.
            .client_detached,
            .client_session_changed,
            => self.sessionsChanged() catch {
                log.warn("failed to queue list-sessions", .{});
            },

            // For the user, not for us.
            .message,
            .config_error,
            => if (notificationNotice(n)) |notice| {
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                actions.append(
                    arena.allocator(),
                    .{ .notice = notice },
                ) catch log.warn("failed to report a tmux notice", .{});
            },

            // Read for the clipboard, if the user asked for that. A
            // buffer going away leaves the clipboard as it is: the user
            // copied it, and still has it.
            .paste_buffer_changed => |info| self.pasteBufferChanged(
                info.name,
            ) catch {
                log.warn("failed to queue reading a paste buffer", .{});
            },
            .paste_buffer_deleted => {},

            // A pane entering or leaving copy mode (or any other mode).
            // tmux does not send a control client what the mode looks
            // like, only its output once it leaves, so there is nothing
            // to show either way yet.
            .pane_mode_changed => |info| log.debug(
                "tmux pane id={} changed mode",
                .{info.pane_id},
            ),

            // What tmux has no notification for: window alerts, pane
            // titles and working directories, the window order and the
            // status line. See `Subscription`.
            .subscription_changed => |sub| self.subscriptionChanged(
                &actions,
                sub,
            ) catch {
                log.warn("failed to handle subscription name={s}", .{sub.name});
            },
        }

        // Send whatever handling this queued. Last, because any of the
        // above may have queued something.
        if (self.state == .command_queue) {
            var arena = self.action_arena.promote(self.alloc);
            defer self.action_arena = arena.state;
            self.flushCommands(arena.allocator(), &actions) catch
                return self.abandon();
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
        flags: []const u8,
        visible_layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        const was_zoomed = window.zoomed_pane_id;

        // Clear our prior window arena and setup our layout
        window.layout = layout: {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            _ = arena.reset(.retain_capacity);

            // The zoomed pane and its size come out of the *visible*
            // layout. syncLayouts below still diffs the real layout: a
            // zoomed window's visible layout lists one pane, and
            // treating that as the set of panes that exist would
            // destroy every other pane in the window.
            window.zoomed_layout = zoomedLayout(
                arena.allocator(),
                flags,
                visible_layout_str,
            );
            window.zoomed_pane_id = if (window.zoomed_layout) |l|
                firstPaneId(l)
            else
                null;

            break :layout Layout.parseWithChecksum(
                arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
        };

        // Its size is its layout's: `list-windows` is not asked again
        // for a resize, so left alone this would be the attach's.
        window.width = window.layout.width;
        window.height = window.layout.height;

        if (window.last_size_request) |want| {
            const shown = window.shownLayout();
            window.size_taken = shown.width != want.cols or
                shown.height != want.rows;
        }

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
        try self.applyPendingNames();
        try self.saveLayout(window, layout_str);

        // The panes a zoom hid are on screen again, and none of them
        // reported while hidden (see `nextResize`), so nothing stale of
        // theirs is in flight. A hold from a resize tmux gave them while
        // they were hidden would swallow their first honest report.
        if (was_zoomed) |zoomed| if (window.zoomed_pane_id != zoomed) {
            self.clearStaleSizes(window.layout, zoomed);
        };
    }

    /// Clear `Pane.stale_size` for every pane in `node` but `except`.
    fn clearStaleSizes(self: *Viewer, node: Layout, except: usize) void {
        switch (node.content) {
            .pane => |id| if (id != except) {
                if (self.panes.get(id)) |pane| pane.stale_size = null;
            },
            .horizontal, .vertical => |children| for (children) |child| {
                self.clearStaleSizes(child, except);
            },
        }
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    /// Bring a paused pane back.
    ///
    /// tmux pauses a pane when the pause-after client flag is set and we
    /// fall behind on it. We never set that flag, but any other client
    /// can set it on us, and while a pane is paused tmux *discards* its
    /// output rather than buffering it (`control_write_output` in
    /// control.c). So resuming is not enough: everything between the
    /// pause and the resume is gone, and a shadow terminal that simply
    /// carried on would be quietly wrong from then on.
    ///
    /// Re-read the pane instead, exactly as if it were new.
    ///
    /// The pane's display says it is catching up until that read has
    /// been applied: until then it shows what it had when tmux stopped
    /// sending, which may be well behind.
    fn pauseRecover(self: *Viewer, pane_id: usize) !void {
        const pane = self.panes.get(pane_id) orelse {
            log.info("pause for untracked pane id={}, dropping", .{pane_id});
            return;
        };

        const resume_cmd = try self.userCommand(
            "refresh-client -A '%{d}:continue'\n",
            .{pane_id},
        );
        errdefer resume_cmd.deinit(self.alloc);

        try self.queueCommands(&([_]Command{resume_cmd} ++
            paneCaptures(pane_id) ++
            [_]Command{.pane_state}));
        pane.full_reads += 1;
        pane.paused = true;
        try self.updatePaneStatus(pane);
    }

    /// The captures that read a pane's content from scratch, in the order
    /// their replies have to be applied.
    ///
    /// tmux has one grid on display per pane plus, only while the pane
    /// is in the alternate screen, the primary grid put aside
    /// (`saved_grid`). `capture-pane` reads the grid on display and
    /// `capture-pane -a` the one put aside. Neither is "the primary" or
    /// "the alternate" screen as such:
    ///
    ///   - On the primary screen, the grid on display is the primary
    ///     and `-a` fails with "no alternate screen".
    ///   - On the alternate screen, the grid on display is the
    ///     alternate and `-a` gives the primary.
    ///
    /// History only ever belongs to the primary screen. tmux stops
    /// collecting it while the alternate screen is up, but keeps what
    /// the primary had, and a history capture of the grid on display
    /// returns that either way. The saved grid has no history: asked
    /// for `-a -S - -E -1` tmux returns its first visible line instead.
    ///
    /// So: history, which always goes to the primary; then the saved
    /// grid, whose success or failure says which screen is up; then the
    /// grid on display, written to that screen. tmux runs commands that
    /// arrive together back to back, without reading pane output in
    /// between, so the screen cannot flip between the last two.
    ///
    /// Each reply is held, and the read applied as a whole once the last
    /// one arrives. See `Pane.read_history`.
    fn paneCaptures(pane_id: usize) [3]Command {
        return [_]Command{.{ .pane_history = pane_id }} ++
            screenCaptures(pane_id);
    }

    /// The captures that read a pane's screens without its history: the
    /// tail of `paneCaptures`, on their own for a lazy attach.
    fn screenCaptures(pane_id: usize) [2]Command {
        return .{
            .{ .pane_saved = pane_id },
            .{ .pane_visible = pane_id },
        };
    }

    /// Whether this server has `refresh-client -B` subscriptions and
    /// `-A` on and off for a pane, both of which came in tmux 3.2.
    fn canSubscribe(self: *const Viewer) bool {
        return self.tmuxVersionAtLeast(3, 2);
    }

    /// A subscription's value changed, or is being reported for the
    /// first time.
    fn subscriptionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        sub: @FieldType(control.Notification, "subscription_changed"),
    ) !void {
        // Checked against whatever session the client is on when the
        // check runs, which can be one we have since left.
        if (sub.session_id) |id| if (id != self.session_id) return;

        const which = Subscription.fromName(sub.name) orelse {
            // Not ours. Another client can subscribe us with
            // `refresh-client -t <us> -B`.
            log.debug("ignoring subscription name={s}", .{sub.name});
            return;
        };

        switch (which) {
            .alerts => {
                const window_id = sub.window_id orelse return;
                const alerts = Alerts.parse(sub.value) orelse {
                    log.info("unexpected window alerts value={s}", .{sub.value});
                    return;
                };
                if (!self.setAlerts(window_id, alerts)) return;

                // Re-send the window list, as for a rename: the flags are
                // shown on the tab, and the GUI already diffs the list.
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                try actions.append(arena.allocator(), .{ .windows = self.windows.items });
            },

            .title => try self.paneName(.title, sub.pane_id orelse return, sub.value),
            .path => try self.paneName(.path, sub.pane_id orelse return, sub.value),

            // Re-listed only when the order is not the one we have: the
            // windows coming and going is announced already, and moves
            // of our own are listed again as they are made.
            .window_order => {
                if (self.state != .command_queue) return;
                if (windowOrderMatches(self.windows.items, sub.value)) return;
                try self.queueCommands(&.{.list_windows});
            },

            .status_left, .status_windows, .status_right => {
                const part: *[]const u8 = switch (which) {
                    .status_left => &self.status.left,
                    .status_windows => &self.status.windows,
                    .status_right => &self.status.right,
                    else => unreachable,
                };

                const text = try plainStatus(self.alloc, sub.value);
                if (std.mem.eql(u8, text, part.*)) {
                    if (text.len > 0) self.alloc.free(text);
                    return;
                }
                if (part.len > 0) self.alloc.free(part.*);
                part.* = text;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                try actions.append(arena.allocator(), .{ .status = self.status });
            },
        }
    }

    /// Record a window's alerts, returning whether they changed.
    fn setAlerts(self: *Viewer, window_id: usize, alerts: Alerts) bool {
        const window: *Window = for (self.windows.items) |*w| {
            if (w.id == window_id) break w;
        } else {
            // A window we have not listed yet. Its listing carries the
            // flags along with everything else.
            log.debug("alerts for unknown window id={}", .{window_id});
            return false;
        };
        if (window.alerts.eql(alerts)) return false;
        window.alerts = alerts;
        return true;
    }

    /// Ask tmux for every window's alerts, on a server too old to tell us
    /// by subscription. Called on output from a window the session is not
    /// on, which is what sets them: a bell, activity, or (on the next
    /// output after it) silence.
    ///
    /// One query at a time, however much output there is. Output that
    /// arrives while one is out may have set a flag after tmux answered
    /// it, so it is remembered and asked again once the answer is in.
    fn requestAlerts(self: *Viewer) Allocator.Error!void {
        switch (self.alerts_query) {
            .idle => {
                try self.queueCommands(&.{.window_alerts});
                self.alerts_query = .sent;
            },
            .sent => self.alerts_query = .stale,
            .stale => {},
        }
    }

    /// The answer to `requestAlerts`: one window per line, its id and
    /// then its flags.
    fn receivedWindowAlerts(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        const stale = self.alerts_query == .stale;
        self.alerts_query = .idle;
        if (stale) try self.requestAlerts();

        var changed = false;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            const sep = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const window_id = output.Variable.parse(
                .window_id,
                line[0..sep],
            ) catch continue;
            const alerts = Alerts.parse(line[sep + 1 ..]) orelse continue;
            if (self.setAlerts(window_id, alerts)) changed = true;
        }

        // One window list however many windows changed.
        if (changed) try actions.append(arena_alloc, .{ .windows = self.windows.items });
    }

    /// What `paneName` records.
    const PaneName = enum { title, path };

    /// What `pending_names` keeps for a pane. Owned.
    const PendingNames = struct {
        title: ?[]const u8 = null,
        path: ?[]const u8 = null,

        fn deinit(self: PendingNames, alloc: Allocator) void {
            if (self.title) |v| alloc.free(v);
            if (self.path) |v| alloc.free(v);
        }
    };

    /// Keep a name for a pane we have not listed yet, replacing any we
    /// already kept of the same kind.
    fn keepPendingName(
        self: *Viewer,
        kind: PaneName,
        pane_id: usize,
        value: []const u8,
    ) Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(copy);
        const gop = try self.pending_names.getOrPut(self.alloc, pane_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const slot = switch (kind) {
            .title => &gop.value_ptr.title,
            .path => &gop.value_ptr.path,
        };
        if (slot.*) |old| self.alloc.free(old);
        slot.* = copy;
    }

    /// Apply the names kept for panes that have since been listed, and
    /// forget the rest: a pane the layout we just took does not have is
    /// one that came and went in between.
    fn applyPendingNames(self: *Viewer) !void {
        defer self.clearPendingNames();
        var it = self.pending_names.iterator();
        while (it.next()) |kv| {
            if (!self.panes.contains(kv.key_ptr.*)) continue;
            if (kv.value_ptr.title) |v| try self.paneName(.title, kv.key_ptr.*, v);
            if (kv.value_ptr.path) |v| try self.paneName(.path, kv.key_ptr.*, v);
        }
    }

    fn clearPendingNames(self: *Viewer) void {
        var it = self.pending_names.valueIterator();
        while (it.next()) |v| v.deinit(self.alloc);
        self.pending_names.clearRetainingCapacity();
    }

    /// The answer to `pane_titles` or `pane_paths`: one pane per line,
    /// its id, a space, and the rest of the line.
    fn receivedPaneNames(
        self: *Viewer,
        kind: PaneName,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const sep = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const pane_id = output.Variable.parse(
                .pane_id,
                line[0..sep],
            ) catch continue;
            try self.paneName(kind, pane_id, line[sep + 1 ..]);
        }
    }

    /// Pass a pane's title or working directory on to whatever shows it,
    /// if it is news. A title comes as `Format.pane_title` has it.
    ///
    /// Compared against the pane's own terminal, which keeps both. A
    /// title the program set itself has already reached it as an OSC 2,
    /// in the same output the surface got, so tmux reporting it a moment
    /// later is not news. Nor is a value the subscription repeats after
    /// the listing that started a pane off.
    fn paneName(
        self: *Viewer,
        kind: PaneName,
        pane_id: usize,
        value: []const u8,
    ) !void {
        const pane: *Pane = self.panes.get(pane_id) orelse {
            // Most likely the pane of a window whose listing is on its
            // way, so the value is kept for it.
            log.debug("{t} for untracked pane id={}", .{ kind, pane_id });
            return self.keepPendingName(kind, pane_id, value);
        };

        switch (kind) {
            .title => {
                // A command name is a file name, so it has no `/`.
                const sep = std.mem.indexOfScalar(u8, value, '/') orelse 0;
                const command = value[0..sep];
                const title = if (sep < value.len and value[sep] == '/')
                    value[sep + 1 ..]
                else
                    value;

                const first = !pane.named;
                const command_changed = !std.mem.eql(u8, pane.command, command);
                const title_changed = first or !std.mem.eql(u8, pane.tmux_title, title);
                try replaceOwned(self.alloc, &pane.command, command);
                try replaceOwned(self.alloc, &pane.tmux_title, title);
                pane.named = true;

                // tmux checks both about once a second, so a program that
                // titles itself as it starts is often reported along with
                // it. When it is the shell that started, it is the other
                // way about: the title is the last thing the program that
                // exited did.
                const set = title.len > 0 and
                    !std.mem.eql(u8, title, self.server_host);
                pane.title_current = set and if (command_changed and title_changed)
                    first or !isShell(command)
                else if (title_changed)
                    true
                else
                    pane.title_current and !command_changed;

                try self.paneTitle(pane);
            },

            .path => {
                // tmux could not find out, which it says with nothing.
                if (value.len == 0) return;
                if (!std.mem.eql(u8, pane.path, value)) {
                    try replaceOwned(self.alloc, &pane.path, value);
                    try self.paneTitle(pane);
                }
                if (pane.terminal.getPwd()) |pwd| {
                    if (std.mem.eql(u8, pwd, value)) return;
                }
                try self.paneOps(pane, &.{.{ .pwd = .{
                    .host = self.server_host,
                    .path = value,
                } }});
            },
        }
    }

    /// Title a pane the way a shell with Ghostty's shell integration
    /// titles a terminal, since a shell under tmux has none: with the
    /// title the running program set, if it set one; at a shell prompt,
    /// with the working directory; otherwise with the command running.
    fn paneTitle(self: *Viewer, pane: *Pane) !void {
        if (!pane.named) return;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const title = if (pane.title_current)
            pane.tmux_title
        else if (pane.path.len > 0 and (pane.command.len == 0 or isShell(pane.command)))
            shortPath(&buf, pane.path, self.server_home)
        else
            pane.command;
        if (title.len == 0) return;

        if (pane.terminal.getTitle()) |current| {
            if (std.mem.eql(u8, current, title)) return;
        }
        try self.paneOps(pane, &.{.{ .title = title }});
    }

    /// Whether a command is a shell, sitting at its prompt rather than
    /// running something. Login shells are named with a leading `-`.
    fn isShell(command: []const u8) bool {
        const shells = [_][]const u8{
            "sh",   "bash", "zsh",   "fish", "dash",  "ksh",    "mksh",
            "tcsh", "csh",  "nu",    "pwsh", "xonsh", "elvish", "ash",
            "yash", "oksh", "loksh",
        };
        const name = std.mem.trimStart(u8, command, "-");
        for (shells) |shell| {
            if (std.mem.eql(u8, name, shell)) return true;
        }
        return false;
    }

    /// A working directory as Ghostty's zsh integration titles it, zsh's
    /// `%(4~|…/%3~|%~)`: the home directory as `~`, and only the last
    /// three parts of anything deeper than that.
    fn shortPath(
        buf: []u8,
        path: []const u8,
        home: []const u8,
    ) []const u8 {
        const tilde = home.len > 1 and std.mem.startsWith(u8, path, home) and
            (path.len == home.len or path[home.len] == '/');
        const rest = if (tilde) path[home.len..] else path;

        var parts: usize = @intFromBool(tilde);
        var it = std.mem.tokenizeScalar(u8, rest, '/');
        while (it.next()) |_| parts += 1;

        if (parts < 4) {
            if (!tilde) return path;
            return std.fmt.bufPrint(buf, "~{s}", .{rest}) catch path;
        }

        // The start of the last three parts.
        var start = std.mem.trimEnd(u8, rest, "/").len;
        for (0..3) |_| {
            start = std.mem.lastIndexOfScalar(u8, rest[0..start], '/') orelse 0;
        }
        return std.fmt.bufPrint(buf, "…{s}", .{rest[start..]}) catch path;
    }

    /// Replace an owned string, empty meaning nothing owned.
    fn replaceOwned(
        alloc: Allocator,
        slot: *[]const u8,
        value: []const u8,
    ) Allocator.Error!void {
        const copy: []const u8 = if (value.len > 0) try alloc.dupe(u8, value) else "";
        if (slot.len > 0) alloc.free(slot.*);
        slot.* = copy;
    }

    /// Whatever shows a pane came into sight, or went out of it.
    ///
    /// Going out of sight changes nothing yet: a pane is often hidden
    /// for a moment, by a tab switch or another window passing over, and
    /// a quiet one costs nothing to keep. Its output is only turned off
    /// once it is still producing some well after it was hidden. See
    /// `hideOutput`.
    ///
    /// Coming back into sight turns it back on, and re-reads the pane:
    /// tmux sends nothing of what happened while it was off.
    fn nextPaneShown(self: *Viewer, req: Input.PaneShown) []const Action {
        if (self.state != .command_queue) return &.{};
        const pane: *Pane = self.panes.get(req.pane_id) orelse return &.{};

        if (!req.shown) {
            if (pane.hidden_since == null) {
                pane.hidden_since = std.Io.Timestamp.now(self.io, .awake);
            }
            return &.{};
        }

        pane.hidden_since = null;
        if (!pane.output_off) return &.{};
        pane.output_off = false;

        // As for a pane tmux paused: everything is read again, from its
        // history down, after its output is picked up from where tmux is.
        var commands = [_]Command{.{ .pane_output_on = req.pane_id }} ++
            paneCaptures(req.pane_id) ++
            [_]Command{.pane_state};
        return self.queueUserCommands(&commands) catch {
            log.warn("failed to turn pane id={} back on", .{req.pane_id});
            return &.{};
        };
    }

    /// A pane's display wants history older than it has. See
    /// `Options.history_chunk`.
    ///
    /// The display says how many rows of scrollback it holds, which are
    /// tmux's newest history lines, one row each (see
    /// `sinkpkg.Op.OlderHistory`). So the next chunk is the lines above
    /// those, ending on the oldest of them: that one line of overlap is
    /// what tells a reply with more in it from tmux having nothing older
    /// (asked to end past the top of its history, tmux clamps both ends
    /// to the top and returns its oldest line alone). Output scrolling
    /// more lines into history before tmux runs the capture only moves
    /// the overlap further down, never leaves a gap, since what the
    /// display holds only grows with it; the display drops what it
    /// already has when the reply lands.
    ///
    /// Not while a read from scratch is on its way for the pane: that
    /// replaces the display's history with the newest chunk, and the
    /// display asks again from there once it has it.
    fn nextHistoryWanted(self: *Viewer, req: Input.HistoryWanted) []const Action {
        if (self.state != .command_queue) return &.{};
        const chunk = self.history_chunk orelse return &.{};
        const pane: *Pane = self.panes.get(req.pane_id) orelse return &.{};

        // Nothing to anchor the read to, or nothing more we may read.
        if (req.held == 0 or pane.older_off) return &.{};
        if (self.history_limit) |limit| if (req.held >= limit) return &.{};
        if (self.historyReadPending(req.pane_id)) return &.{};

        if (pane.older_reading) {
            pane.older_wanted = req;
            return &.{};
        }

        return self.queueUserCommands(&.{self.olderHistoryRead(pane, req, chunk)}) catch {
            log.warn("failed to read older history for pane id={}", .{req.pane_id});
            pane.older_reading = false;
            return &.{};
        };
    }

    /// The command reading what `req` asks for, marking it in flight.
    fn olderHistoryRead(
        self: *const Viewer,
        pane: *Pane,
        req: Input.HistoryWanted,
        chunk: u32,
    ) Command {
        pane.older_reading = true;
        pane.older_wanted = null;
        const oldest: ?usize = if (req.all) null else req.held + chunk;
        return .{ .pane_older_history = .{
            .pane_id = req.pane_id,
            .oldest = if (self.history_limit) |limit|
                @min(oldest orelse limit, limit)
            else
                oldest,
            .newest = req.held,
            .read = pane.history_reads,
        } };
    }

    /// Whether a read that replaces the pane's history is still to land:
    /// one queued, or one whose history has arrived and whose screens
    /// have not.
    fn historyReadPending(self: *Viewer, pane_id: usize) bool {
        if (self.panes.get(pane_id)) |pane| {
            if (pane.read_history != null) return true;
        }
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |command| switch (command.*) {
            .pane_history,
            .pane_history_all,
            => |id| if (id == pane_id) return true,
            else => {},
        };
        return false;
    }

    /// Older history the display asked for has arrived.
    fn receivedOlderHistory(
        self: *Viewer,
        req: Command.OlderHistory,
        content: ?[]const u8,
    ) !void {
        const pane: *Pane = self.panes.get(req.pane_id) orelse return;
        pane.older_reading = false;

        // More than the line of overlap, or tmux had nothing older. The
        // display may still find it all overlaps, if output scrolled
        // that much in the meantime.
        if (content) |raw| if (std.mem.indexOfScalar(u8, raw, '\n') != null) {
            const bytes = try self.decodeCapture(raw);
            defer self.alloc.free(bytes);
            try self.paneOps(pane, &.{.{ .older_history = .{
                .bytes = bytes,
                .newest = req.newest,
                .read = req.read,
            } }});
        };

        // What was asked for meanwhile. Its count of rows held may be
        // from before this reply reached the display, which only costs
        // an overlap read twice: the display drops what it has.
        const wanted = pane.older_wanted orelse return;
        const chunk = self.history_chunk orelse return;
        if (self.historyReadPending(req.pane_id)) {
            pane.older_wanted = null;
            return;
        }
        try self.queueCommands(&.{self.olderHistoryRead(pane, wanted, chunk)});
    }

    /// The display needs all of the pane's history. See
    /// `Input.read_history`.
    ///
    /// Read from scratch rather than above what the display has: that
    /// needs nothing from the display, which may be anywhere between
    /// having asked and having its answer, and lands in order behind
    /// any read already on its way, whatever it is.
    fn nextReadHistory(self: *Viewer, req: Input.PaneId) []const Action {
        if (self.state != .command_queue) return &.{};
        if (!self.panes.contains(req.pane_id)) return &.{};

        const commands = [_]Command{.{ .pane_history_all = req.pane_id }} ++
            screenCaptures(req.pane_id) ++
            [_]Command{.pane_state};
        return self.queueUserCommands(&commands) catch {
            log.warn("failed to read all history for pane id={}", .{req.pane_id});
            return &.{};
        };
    }

    /// The display refused older history that did not line up with its
    /// own. See `Input.history_drifted`.
    ///
    /// Read the pane again from scratch, which leaves the two agreeing
    /// again: the display then holds the newest chunk exactly as tmux has
    /// it, and asks for the rest from there. Once only, though. Refused
    /// again right after such a re-read, against the history it left,
    /// the drift is not something reading again fixes, and asking again
    /// would only go round in a loop; older history stops being read for
    /// the pane until it is read from scratch for some other reason.
    fn nextHistoryDrifted(self: *Viewer, req: Input.HistoryDrifted) []const Action {
        if (self.state != .command_queue) return &.{};
        const pane: *Pane = self.panes.get(req.pane_id) orelse return &.{};

        // Measured against a history that has since been replaced, or
        // one being replaced already.
        if (req.read != pane.history_reads or pane.drift_reread) return &.{};
        if (self.historyReadPending(req.pane_id)) return &.{};

        if (pane.drift_read == req.read) {
            log.warn(
                "pane id={} history drifted from tmux's again right after a re-read, no longer reading older history",
                .{req.pane_id},
            );
            pane.older_off = true;
            pane.older_wanted = null;
            return &.{};
        }

        log.info("pane id={} history drifted from tmux's, reading it again", .{req.pane_id});
        const commands = paneCaptures(req.pane_id) ++ [_]Command{.pane_state};
        const actions = self.queueUserCommands(&commands) catch {
            log.warn("failed to read pane id={} again", .{req.pane_id});
            return &.{};
        };
        pane.drift_reread = true;
        return actions;
    }

    /// Turn a pane's output off if it has been out of sight for long
    /// enough. Called on its output, which is the only time it matters:
    /// a hidden pane producing nothing costs nothing.
    ///
    /// The output that brought us here is still applied, as is anything
    /// tmux sent before it saw the command. It is all replaced when the
    /// pane is shown again and re-read.
    fn hideOutput(
        self: *Viewer,
        pane_id: usize,
        pane: *Pane,
    ) Allocator.Error!void {
        if (pane.output_off or self.hidden_output_off_after == 0) return;
        const since = pane.hidden_since orelse return;
        if (!self.canSubscribe()) return;

        const now = std.Io.Timestamp.now(self.io, .awake);
        const after: std.Io.Duration = .fromSeconds(self.hidden_output_off_after);
        if (since.durationTo(now).nanoseconds < after.nanoseconds) return;

        try self.queueCommands(&.{.{ .pane_output_off = pane_id }});
        pane.output_off = true;
        log.info("turned off output for hidden pane id={}", .{pane_id});
    }

    /// Record a window's new name.
    fn windowRenamed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        name: []const u8,
    ) !void {
        const window: *Window = for (self.windows.items) |*w| {
            if (w.id == window_id) break w;
        } else {
            log.info("rename for unknown window id={}", .{window_id});
            return;
        };
        if (std.mem.eql(u8, window.name, name)) return;

        // Allocated before the old one is released, so a failure here
        // leaves the window with the name it already had.
        const copy = try self.alloc.dupe(u8, name);
        self.alloc.free(window.name);
        window.name = copy;

        // Re-send the window list, as for the current window: the name is
        // what the GUI shows on the tab, and it has no other way to learn
        // it changed. No round trip; the notification carried the name.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), .{ .windows = self.windows.items });
    }

    /// A window we were showing is gone.
    ///
    /// Refresh the whole list rather than pruning by hand: `syncLayouts`
    /// already drops the window, destroys its panes and closes their
    /// sinks, and doing that in two places is where a lifetime bug would
    /// live. The cost is one round trip.
    fn windowClose(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id;
        try self.queueCommands(&.{.list_windows});
    }

    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueCommands(&.{.list_windows});
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.*.destroy(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| {
            // The zoomed pane first, at the size tmux shows it at: a
            // pane takes its size from the first node naming it, so the
            // real layout after this sizes only the panes behind it,
            // which tmux leaves at their unzoomed sizes. See
            // `Window.zoomed_layout`.
            if (window.zoomed_layout) |zoomed| try initLayout(
                self.io,
                self.alloc,
                &self.panes,
                &panes,
                zoomed,
            );

            try initLayout(
                self.io,
                self.alloc,
                &self.panes,
                &panes,
                window.layout,
            );
        }

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        // TODO: errdefer cleanup
        {
            var added_ids: std.ArrayList(usize) = .empty;
            defer added_ids.deinit(self.alloc);
            var any_added = false;
            var reread = false;
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) {
                    // tmux resized this pane, and so did we, but not the
                    // same way. Each side reflows the primary screen by
                    // its own rules (which lines come back out of the
                    // history when it grows, where the cursor's line
                    // ends up, whether a shell prompt is cleared for the
                    // shell to redraw) and resizes the alternate screen
                    // without reflow by its own rules too. The program
                    // in the pane then repaints for the new size, and a
                    // TUI repaints only what it thinks changed, relative
                    // to tmux's idea of the screen. Wherever ours
                    // differs, the difference stays, which is the mess
                    // left behind by fullscreening a window, dragging a
                    // divider, or anything else that resizes a pane.
                    //
                    // So read back what tmux has on display: its screens
                    // alone, as a lazy attach does first. The reply is a
                    // snapshot taken in order with the pane's output, so
                    // it replaces our screens at the same point in the
                    // stream that tmux's were at. History is left alone:
                    // it is not on display, and reading it again is the
                    // expensive part of an attach.
                    //
                    // Reads already in flight are left to land. They come
                    // back first, in order, and whatever they show this
                    // read replaces: a full read applies its history and
                    // screens in one go when its last reply arrives, and
                    // this one, holding no history, never consumes or
                    // completes a full read's (see `receivedPaneVisible`).
                    //
                    // Not for a pane nothing is showing. One in a hidden
                    // window, or whose output is off, is read whole when
                    // it is shown again, and nothing of it is on screen
                    // until then.
                    //
                    // Unless history is read on demand. Older lines go
                    // in above ours by counting lines back from the
                    // screen, which only works while our scrollback and
                    // tmux's history agree line for line, and after each
                    // has reflowed its own way they do not. So the pane
                    // is read from scratch instead, which with
                    // `history_chunk` is its newest chunk of history
                    // alone; the rest is read again as it is scrolled
                    // up to. Not counted as a full read: it says nothing
                    // to the user about history still to come.
                    const pane = kv.value_ptr.*;
                    if (pane.reread) {
                        pane.reread = false;
                        if (!pane.output_off and !paneHiddenIn(windows, pane_id)) {
                            reread = true;
                            if (self.history_chunk != null) {
                                try self.queueCommands(&paneCaptures(pane_id));
                            } else {
                                try self.queueCommands(&screenCaptures(pane_id));
                            }
                        }
                    }
                    continue;
                }
                any_added = true;

                // Read when the window is shown. See `Window.hidden`.
                if (paneHiddenIn(windows, pane_id)) continue;
                try added_ids.append(self.alloc, pane_id);
            }
            const added = any_added;
            if (added_ids.items.len > 0) try self.queuePaneReads(&panes, added_ids.items);

            // Once per session, once its windows are known, so the first
            // values (within a second) find them.
            //
            // A session change starts a new viewer, so this is sent again
            // then. That matters: subscribing under the same names starts
            // the subscriptions over and every value is sent afresh. Left
            // as they were, tmux would only send what differs from what it
            // last sent this client, and a pane we had before the change
            // would never be told it.
            if (!self.subscribed and self.canSubscribe()) {
                try self.queueCommands(&.{.{ .subscribe = &.{ .alerts, .title, .path } }});
                self.subscribed = true;
            }

            // If we added or re-read any panes, then we also want to
            // resync the pane state (terminal modes and cursor positions
            // and so on), once their content is in.
            if (added or reread) try self.queueCommands(&.{.pane_state});

            // And learn what they are called and where they are. A server
            // that can subscribe tells us that for every pane by itself,
            // including ones it reports before we have listed them: see
            // `pending_names`. One that cannot is asked.
            if (added and !self.canSubscribe()) try self.queueCommands(&.{
                .pane_titles,
                .pane_paths,
            });
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                entry_const.value.destroy(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// Read new panes from tmux: their content. Their state (terminal
    /// modes, cursor positions and so on) is the caller's to read after,
    /// once the content is in; only a lazy read's screens have theirs
    /// read here, to be right until the full reads land.
    ///
    /// Eagerly, each pane is read whole, history and all, and nothing of
    /// the next pane arrives before the last pane's history has. With
    /// `lazy_history` every pane's screen is read first, cheaply, and
    /// the full reads follow: the session is on screen as soon as its
    /// screens are, and its history fills in behind. The full read
    /// replaces the screen read rather than adding to it, since the two
    /// cannot be stitched together: output arriving in between moves
    /// lines into tmux's history that our screen already scrolled. It is
    /// applied in one go (see `Pane.read_history`), so the pane does not
    /// blank while it arrives, and once it has, the pane is exactly what
    /// an eager read would have made it.
    fn queuePaneReads(
        self: *Viewer,
        panes: *const PanesMap,
        ids: []const usize,
    ) !void {
        if (self.lazy_history) {
            for (ids) |id| try self.queueCommands(&screenCaptures(id));
            try self.queueCommands(&.{.pane_state});
        }

        for (ids) |id| {
            try self.queueCommands(&paneCaptures(id));
            const pane = panes.get(id) orelse continue;
            pane.full_reads += 1;
            try self.updatePaneStatus(pane);
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        session_name: []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        // Options carry over: they came from the user's config, not from
        // the session that just ended.
        var replacement: Viewer = try .init(self.io, self.alloc, .{
            .pause_after = self.pause_after,
            .hidden_output_off_after = self.hidden_output_off_after,
            .follow_window_order = self.follow_window_order,
            .attach_layout = self.attach_layout,
            .status_line = self.status_line,
            .lazy_history = self.lazy_history,
            .reattach_command = self.reattach_command,
            .history_limit = self.history_limit,
            .history_chunk = self.history_chunk,
            .mirror_paste_buffers = self.mirror_paste_buffers,
            .client_flags = self.client_flags,
        });
        errdefer replacement.deinit();

        // Not a fact about the session: `switch-client -r` is how tmux
        // changes it, and the list that follows says whether it did.
        replacement.read_only = self.read_only;
        replacement.read_only_noticed = self.read_only_noticed;
        replacement.read_only_untold = self.read_only_untold;

        // The server's sessions, which are still the same ones, and
        // whether anything wants them. Read again below, since which
        // session we are attached to is part of it.
        std.mem.swap(std.ArrayList(Session), &replacement.sessions, &self.sessions);
        replacement.sessions_wanted = self.sessions_wanted;

        // Kept, for the command lines carried over below to be told apart
        // by the same marker as everything typed from now on.
        replacement.command_marker = self.command_marker;

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Everything we sent for the old session is still going to be
        // answered, and those answers come before the answer to anything
        // sent from here on: tmux answers in the order it was asked. So
        // it all stays at the front of the queue, as sent. What it asked
        // about the old session is an `orphan` now, its answer discarded.
        //
        // A command line the user typed is not about any session, and
        // is carried over as it is: its answers end at its marker rather
        // than after a count, so it could not be counted out anyway --
        // and `switch-client` is a very likely thing to type.
        {
            try replacement.command_queue.ensureUnusedCapacity(
                replacement.alloc,
                self.commands_sent + 2,
            );
            var it = self.command_queue.iterator(.forward);
            var i: usize = 0;
            while (it.next()) |command| : (i += 1) {
                if (i >= self.commands_sent) break;
                switch (command.*) {
                    .prompt => {
                        replacement.command_queue.appendAssumeCapacity(command.*);
                        command.* = .orphan;
                    },
                    else => replacement.command_queue.appendAssumeCapacity(.orphan),
                }
            }
            replacement.commands_sent = self.commands_sent;
        }

        // Setup our command queue and put ourselves in the command queue
        // state. The list is sent by the caller's flush.
        try replacement.queueCommands(&.{ .client_readonly, .list_windows });
        try replacement.sessionsChanged();
        replacement.state = .command_queue;

        // A pane we turned off stays off: that is per client, not per
        // session. The replacement does not know it is, and would show
        // it frozen should it come back.
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| if (kv.value_ptr.*.output_off) {
                try replacement.queueCommands(&.{
                    .{ .pane_output_on = kv.key_ptr.* },
                });
            };
        }

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);
        if (self.server_host.len > 0) {
            replacement.server_host = try replacement.alloc.dupe(u8, self.server_host);
        }
        if (self.server_home.len > 0) {
            replacement.server_home = try replacement.alloc.dupe(u8, self.server_home);
        }

        // Before the swap, so the empty window list going out first
        // already names the session it is the start of.
        try replacement.setSessionName(session_name);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;

        // The status line is the client's, and tmux only says when part
        // of it changes. See `status`. Moved, not copied: the old viewer
        // is freed next and must not take it along.
        replacement.status = self.status;
        self.status = .{};
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
    }

    /// A session was renamed. If it is ours, re-send the window list so
    /// the GUI sees the new name: the name is a fact about the set.
    fn sessionRenamed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        name: []const u8,
    ) Allocator.Error!void {
        try self.sessionsChanged();
        if (session_id != self.session_id) return;
        if (std.mem.eql(u8, self.session_name, name)) return;
        try self.setSessionName(name);

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), .{ .windows = self.windows.items });
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // A command line the user typed takes every reply until its
        // marker. See `nextCommandLine`.
        if (self.command_queue.first()) |head| if (head.* == .prompt and
            self.commands_sent > 0)
        {
            const prompt = head.prompt;
            const text = std.mem.trim(u8, content, " \t\r\n");
            if (is_err or !std.mem.eql(u8, text, prompt.marker)) {
                try prompt.collect(self.alloc, text, is_err);
                return;
            }

            self.command_queue.deleteOldest(1);
            self.commands_sent -= 1;
            defer prompt.destroy(self.alloc);

            var arena = self.action_arena.promote(self.alloc);
            defer self.action_arena = arena.state;
            const arena_alloc = arena.allocator();
            if (prompt.output.items.len > 0) try actions.append(arena_alloc, .{ .notice = .{
                .kind = .command_output,
                .text = try arena_alloc.dupe(u8, prompt.output.items),
            } });
            if (prompt.errors.items.len > 0) try actions.append(arena_alloc, .{ .notice = .{
                .kind = .command_error,
                .text = try arena_alloc.dupe(u8, prompt.errors.items),
            } });
            return;
        };

        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return;
        };

        // Only commands we sent can be answered. Anything else means we
        // lost track of the pairing, and every reply from here on would
        // be read as the answer to the wrong question.
        if (self.commands_sent == 0) {
            log.warn("block output for a command not yet sent", .{});
            return error.UnexpectedReply;
        }
        self.command_queue.deleteOldest(1);
        self.commands_sent -= 1;
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            // A command run on the user's behalf failing is something
            // they should hear about: they asked for a split and none
            // appeared. Ours failing is a bug, and is handled (or not) by
            // whatever parses the reply below.
            .user => if (is_err) {
                const text = std.mem.trim(u8, content, " \t\r\n");
                if (text.len > 0) try actions.append(arena_alloc, .{ .notice = .{
                    .kind = .command_error,
                    .text = text,
                } });
            },

            // Nothing to read: the flag is set or it is not, and tmux
            // says so by erroring the block, which is handled above.
            .pause_after => {},

            // Their answer is that they are no longer unanswered. A
            // failure (the pane closed on its way) is put right by the
            // notifications and layouts that closing brings.
            .select_window, .select_pane => if (is_err) log.info(
                "tmux refused {t}: {s}",
                .{ command, std.mem.trim(u8, content, " \t\r\n") },
            ),

            // An answer about a session we have left. Nothing still cares.
            .orphan => log.debug(
                "discarding a reply from before the session changed",
                .{},
            ),

            // Taken care of above, before it could get here.
            .prompt => unreachable,

            .pane_state => try self.receivedPaneState(content),

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            // These only fail for a pane that has gone, and the error
            // text is not content. They are still a read finishing.
            .pane_history => |id| try self.receivedPaneHistory(
                id,
                if (is_err) null else content,
                false,
            ),

            .pane_history_all => |id| try self.receivedPaneHistory(
                id,
                if (is_err) null else content,
                true,
            ),

            // Failing is the answer here: no saved grid means the pane
            // is on its primary screen.
            .pane_saved => |id| try self.receivedPaneSaved(
                id,
                if (is_err) null else content,
            ),

            .pane_visible => |id| try self.receivedPaneVisible(
                id,
                if (is_err) null else content,
            ),

            .pane_older_history => |req| try self.receivedOlderHistory(
                req,
                if (is_err) null else content,
            ),

            .tmux_version => try self.receivedTmuxVersion(
                arena_alloc,
                actions,
                content,
            ),

            .client_readonly => self.receivedReadOnly(
                std.mem.eql(u8, std.mem.trim(u8, content, " \t\r\n"), "1"),
            ),

            // Ours, so a failure is a bug rather than news for the user,
            // and leaves the GUI as it was: without live alerts, titles
            // or working directories, or with a pane's output as it was.
            .subscribe,
            .pane_output_on,
            .pane_output_off,
            => if (is_err) log.warn(
                "tmux refused {t}: {s}",
                .{ command, std.mem.trim(u8, content, " \t\r\n") },
            ),

            .window_alerts => if (!is_err) {
                try self.receivedWindowAlerts(arena_alloc, actions, content);
            },

            .ours => |v| if (is_err) log.warn(
                "tmux refused {s}: {s}",
                .{ std.mem.trim(u8, v, " \n"), std.mem.trim(u8, content, " \t\r\n") },
            ),

            // A failure leaves the windows as tmux has them.
            .saved_layouts => try self.receivedSavedLayouts(if (is_err) "" else content),

            .pane_titles => if (!is_err) {
                try self.receivedPaneNames(.title, content);
            },

            .pane_paths => if (!is_err) {
                try self.receivedPaneNames(.path, content);
            },

            .client_flags => if (is_err) log.warn(
                "tmux refused our client flags: {s}",
                .{std.mem.trim(u8, content, " \t\r\n")},
            ),

            .list_sessions => if (!is_err) {
                try self.receivedSessions(arena_alloc, actions, content);
            },

            .paste_buffer => if (!is_err) {
                try receivedPasteBuffer(arena_alloc, actions, content);
            },
        }
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        // The version on its own first, before the rest of the line has
        // to make sense: a tmux old enough to be refused may not know
        // every variable we ask about, and failing to read its reply
        // would end the session without saying why.
        const version = line[0 .. std.mem.indexOfScalar(
            u8,
            line,
            Format.tmux_version.delim,
        ) orelse line.len];
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
            self.tmux_version = "";
        }
        self.tmux_version = try self.alloc.dupe(u8, version);

        if (self.tmuxTooOld()) return self.refuseOldTmux(arena_alloc, actions);

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };
        self.receivedReadOnly(data.client_readonly);

        const host = try self.alloc.dupe(u8, data.host);
        if (self.server_host.len > 0) self.alloc.free(self.server_host);
        self.server_host = host;

        if (data.HOME.len > 0) {
            const home = try self.alloc.dupe(u8, data.HOME);
            if (self.server_home.len > 0) self.alloc.free(self.server_home);
            self.server_home = home;
        }

        // Now that the version is known, and only now: an unreadable
        // version is let in (see `tmuxTooOld`), and a server that turns
        // out not to have the flag answers with an error rather than
        // ignoring it.
        if (self.pause_after > 0 and self.tmuxVersionAtLeast(3, 2)) {
            try self.queueCommands(&.{.{ .pause_after = self.pause_after }});
        }

        // The same command and the same version, but on their own: a
        // flag tmux does not know is ignored, and pause-after is not
        // held up by one of these.
        if (self.client_flags.any() and self.tmuxVersionAtLeast(3, 2)) {
            try self.queueCommands(&.{.{ .client_flags = self.client_flags }});
        }

        // Subscriptions landed in 3.2 too.
        if (self.tmuxVersionAtLeast(3, 2)) {
            if (self.follow_window_order) {
                try self.queueCommands(&.{.{ .subscribe = &.{.window_order} }});
            }
            if (self.status_line) try self.queueCommands(&.{
                .{ .subscribe = &.{.status_left} },
                .{ .subscribe = &.{.status_windows} },
                .{ .subscribe = &.{.status_right} },
            });
        }
    }

    /// Whether `value`, the window ids `#{W:#{window_id} }` lists in
    /// tmux's order, is the order we have them in.
    fn windowOrderMatches(windows: []const Window, value: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        for (windows) |w| {
            const token = it.next() orelse return false;
            if (token.len < 2 or token[0] != '@') return false;
            const id = std.fmt.parseInt(usize, token[1..], 10) catch return false;
            if (id != w.id) return false;
        }
        return it.next() == null;
    }

    /// tmux's formatted status text as plain text: its style directives
    /// (`#[...]`) taken out, and control characters with them. Empty is
    /// returned as the static empty string, so it needs no freeing.
    fn plainStatus(alloc: Allocator, value: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var i: usize = 0;
        while (i < value.len) {
            if (value[i] == '#' and i + 1 < value.len and value[i + 1] == '[') {
                const end = std.mem.indexOfScalarPos(u8, value, i, ']') orelse
                    value.len - 1;
                i = end + 1;
                continue;
            }
            const c = value[i];
            i += 1;
            if (c < 0x20 or c == 0x7F) continue;
            try out.append(alloc, c);
        }

        if (out.items.len == 0) {
            out.deinit(alloc);
            return "";
        }
        return try out.toOwnedSlice(alloc);
    }

    /// Leave a session whose tmux is older than we support, and say why.
    ///
    /// Nothing has been built yet: the version is asked first on attach,
    /// and the window list sent alongside it is answered after this. So
    /// the user sees one clear message instead of a session that opens
    /// and then misbehaves. We detach rather than simply stop listening,
    /// because tmux would otherwise keep a client attached that nobody
    /// reads, and the host's terminal would stay in control mode; the
    /// session itself keeps running for a client that can show it.
    fn refuseOldTmux(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
    ) Allocator.Error!void {
        log.warn("tmux {s} is too old for control mode, detaching", .{self.tmux_version});
        const text = try std.fmt.allocPrint(
            arena_alloc,
            "tmux {s} is too old: Ghostty's tmux integration needs tmux {d}.{d} or newer",
            .{ self.tmux_version, min_tmux_release.major, min_tmux_release.minor },
        );
        try actions.ensureUnusedCapacity(arena_alloc, 3);
        actions.appendAssumeCapacity(.{ .notice = .{ .kind = .unsupported, .text = text } });
        actions.appendAssumeCapacity(.{ .command = "detach-client\n" });

        // Everything after this, the window list and the `%exit` the
        // detach earns included, is for a viewer that has gone.
        _ = self.defunct();
        actions.appendAssumeCapacity(.exit);
    }

    /// tmux told us whether this client is read-only. Only a change is
    /// news, and being writable is not news on attach. The user is told
    /// with the window list that follows: see `read_only_untold`.
    fn receivedReadOnly(self: *Viewer, read_only: bool) void {
        if (read_only == self.read_only) return;
        self.read_only = read_only;
        self.read_only_noticed = null;
        self.read_only_untold = true;
    }

    /// Tell the user about a change of `read_only`, if there is one to
    /// tell.
    fn tellReadOnly(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
    ) Allocator.Error!void {
        if (!self.read_only_untold) return;
        self.read_only_untold = false;
        const read_only = self.read_only;
        try actions.append(arena_alloc, .{ .notice = .{
            .kind = .message,
            .text = if (read_only)
                "this client is read-only: nothing typed here reaches the session"
            else
                "this client is no longer read-only",
        } });
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before.
        const actions_len = actions.items.len;
        errdefer actions.shrinkRetainingCapacity(actions_len);

        // This stores our new window state from this list-windows output.
        // Ownership of each Window's layout arena transfers into
        // `self.windows` via syncLayouts; this list only owns the
        // ArrayList buffer itself.
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);

        // Only on the error path: on success `syncLayouts` copies these
        // structs into `self.windows` and takes their memory with them.
        // It cannot fail after that copy -- see the `comptime unreachable`
        // there -- so this never runs against windows we have handed off.
        errdefer for (windows.items) |*w| w.deinit(self.alloc);

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };

            // Parse the layout
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };

            const zoomed: ?Layout = if (data.window_zoomed_flag) zoomedLayout(
                window_alloc,
                "Z",
                data.window_visible_layout,
            ) else null;

            const name = try self.alloc.dupe(u8, data.window_name);
            errdefer self.alloc.free(name);

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .name = name,
                .active = data.window_active,
                .active_pane_id = data.pane_id,
                .alerts = .{
                    .bell = data.window_bell_flag,
                    .activity = data.window_activity_flag,
                    .silence = data.window_silence_flag,
                },
                .hidden = data.@"@ghostty-hidden",
                .zoomed_layout = zoomed,
                .zoomed_pane_id = if (zoomed) |l| firstPaneId(l) else null,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
            });
        }

        // Which window tmux is on and each window's active pane, learned
        // here rather than waited for: tmux only notifies a change, so
        // without this the first focus would select what tmux very
        // likely has already. Unless a select of ours is on its way,
        // which this reply may be from before: then where it will leave
        // tmux stands, as it does against a notification (see
        // `sessionWindowChanged`).
        const window_select = self.windowSelectUnanswered();
        for (windows.items) |*w| {
            if (window_select) {
                w.active = self.current_window_id == w.id;
            } else if (w.active) {
                self.current_window_id = w.id;
            }

            if (self.paneSelectUnanswered(w.id)) {
                for (self.windows.items) |old| {
                    if (old.id == w.id) w.active_pane_id = old.active_pane_id;
                }
            }

            // Laid out on attach, as `attach_layout` says: the windows
            // in this first list, and only once.
            w.arrange_pending = !self.windows_listed and self.attach_layout != .tmux;
            for (self.windows.items) |*old| if (old.id == w.id) {
                w.arrange_pending = old.arrange_pending;
                w.saved_hash = old.saved_hash;
                w.saved_layout = old.saved_layout;
                old.saved_layout = null;
            };
        }

        // While ours is still the old list, to compare against.
        try self.syncHidden(windows.items);

        // Sync into self.windows first. The `.windows` action must point at
        // `self.windows.items` (stable for the duration of next()), not the
        // temporary list buffer which is freed by the defer above — otherwise
        // logging/formatting the action is a use-after-free.
        try self.syncLayouts(windows.items);
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
        try self.applyPendingNames();
        try self.tellReadOnly(arena_alloc, actions);

        if (!self.windows_listed) {
            self.windows_listed = true;
            if (!self.saved_layouts_known) try self.queueCommands(&.{.saved_layouts});
        }
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };

            try self.paneOps(entry.value_ptr.*, &.{.{ .pane_state = data }});
        }
    }

    /// Mirror a pane's operations somewhere else, typically a surface that
    /// renders the pane.
    ///
    /// Attach while the pane's initial captures are still in flight, which
    /// is what happens if you attach in response to a `.windows` action:
    /// the captures are queued before that action is emitted, so their
    /// replies reach the sink. A pane that has been alive for a while will
    /// only mirror what happens from now on; re-capturing for a late
    /// attacher is not implemented yet.
    ///
    /// The sink's first op is always a `.resize` carrying the pane's
    /// current size, so a consumer never has to guess the geometry it is
    /// about to receive content for. Its title and working directory
    /// follow, if tmux has told us them.
    ///
    /// Fails with `PaneMidSequence` if the pane's parser is part way
    /// through an escape sequence. The sink's parser starts fresh, so it
    /// would receive the tail without the prefix and print it as text.
    /// Attaching again once the sequence completes will succeed.
    ///
    /// An existing sink for the pane is closed and replaced.
    pub fn attachPane(
        self: *Viewer,
        pane_id: usize,
        s: Sink,
    ) error{ UnknownPane, PaneMidSequence }!void {
        const entry = self.panes.getEntry(pane_id) orelse
            return error.UnknownPane;
        const pane: *Pane = entry.value_ptr.*;

        if (!pane.stream.ground() or pane.passthrough.midSequence()) {
            log.info(
                "attach to pane id={} while mid-sequence, refusing",
                .{pane_id},
            );
            return error.PaneMidSequence;
        }

        if (pane.sink) |old| old.close();
        pane.sink = s;

        s.send(&.{.{ .resize = .{
            .cols = pane.terminal.cols,
            .rows = pane.terminal.rows,
        } }});

        // What the pane is called and where it is, if we already know:
        // tmux only says again when they change.
        if (pane.terminal.getTitle()) |title| s.send(&.{.{ .title = title }});
        if (pane.terminal.getPwd()) |pwd| s.send(&.{.{ .pwd = .{
            .host = self.server_host,
            .path = pwd,
        } }});

        // A display starts out live, and this one may be attached to a
        // pane whose history is still on its way.
        if (pane.status != .live) s.send(&.{.{ .pane_status = pane.status }});
    }

    /// Stop mirroring a pane. Closes the sink. Safe to call for a pane
    /// that is unknown or has nothing attached.
    pub fn detachPane(self: *Viewer, pane_id: usize) void {
        const entry = self.panes.getEntry(pane_id) orelse return;
        const pane: *Pane = entry.value_ptr.*;
        if (pane.sink) |s| {
            s.close();
            pane.sink = null;
        }
    }

    /// Apply operations to a pane's terminal and mirror them to its sink.
    ///
    /// Both sides see the same ops and, apart from the byte stream, run the
    /// same `applyOp`, which is what stops the shadow terminal and the
    /// attached one from drifting.
    fn paneOps(
        self: *Viewer,
        pane: *Pane,
        ops: []const sinkpkg.Op,
    ) !void {
        for (ops) |op| switch (op) {
            // The stream is per-pane and persistent, so it can't go
            // through applyOp.
            .bytes => |b| pane.stream.nextSlice(b),

            // Nothing in it is for us: it never touches the grid, and a
            // notification or an image is the display's business.
            .passthrough => {},

            // Nor is this. We keep only the newest few pages of history
            // (the default scrollback limit), and older lines would be
            // pruned as soon as they went in.
            .older_history => {},

            else => try sinkpkg.applyOp(self.alloc, &pane.terminal, op),
        };

        if (pane.sink) |s| s.send(ops);
    }

    fn receivedPaneHistory(
        self: *Viewer,
        id: usize,
        content: ?[]const u8,
        all: bool,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // Held until the grid on display arrives: see `Pane.read_history`.
        // An empty history still marks this as a full read.
        const history = try self.decodeCapture(content orelse "");
        if (pane.read_history) |old| self.alloc.free(old);
        pane.read_history = history;
        pane.read_all = all;
    }

    /// The saved grid: the primary screen's content while the pane is
    /// in the alternate screen, or null when tmux said there is none,
    /// which means the pane is on its primary screen.
    fn receivedPaneSaved(
        self: *Viewer,
        id: usize,
        content: ?[]const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane saved grid for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        if (pane.read_saved) |old| self.alloc.free(old);
        pane.read_saved = null;

        const saved = content orelse {
            pane.visible_screen = .primary;
            return;
        };
        pane.visible_screen = .alternate;
        pane.read_saved = try self.decodeCapture(saved);
    }

    /// The grid on display, for whichever screen the saved-grid capture
    /// before it said that is, or null if tmux could not give it. This
    /// ends a read, and applies all of it at once.
    fn receivedPaneVisible(
        self: *Viewer,
        id: usize,
        content: ?[]const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        const history = pane.read_history;
        pane.read_history = null;
        defer if (history) |v| self.alloc.free(v);
        const saved = pane.read_saved;
        pane.read_saved = null;
        defer if (saved) |v| self.alloc.free(v);

        if (content) |visible_raw| {
            const visible = try self.decodeCapture(visible_raw);
            defer self.alloc.free(visible);

            var ops: [13]sinkpkg.Op = undefined;
            var len: usize = 0;

            // The history, which always goes to the primary screen. Its
            // replay populates the active area too, but scrolling that
            // into history leaves only the scrollback we were after, and
            // the active contents follow. It replaces whatever the
            // primary screen held, scrollback and all: this is the
            // pane's whole history, and a pane read again already has
            // the older part of it.
            if (history) |v| for ([_]sinkpkg.Op{
                .{ .switch_screen = .primary },
                .erase_all,
                .{ .replay = v },
                .scroll_into_history,
            }) |op| {
                ops[len] = op;
                len += 1;
            };

            // The saved grid, or, when there is none, an alternate
            // screen emptied: whatever ours holds is stale, since a
            // re-read can find a pane that has left the alternate screen
            // since we last looked.
            const saved_ops: []const sinkpkg.Op = switch (pane.visible_screen) {
                .primary => &.{
                    .{ .switch_screen = .alternate },
                    .erase_and_home,
                },
                .alternate => &.{
                    .{ .switch_screen = .primary },
                    .erase_and_home,
                    .{ .replay = saved orelse "" },
                    .trim_trailing_blanks,
                },
            };
            for (saved_ops) |op| {
                ops[len] = op;
                len += 1;
            }

            // Then the grid on display, on top.
            for ([_]sinkpkg.Op{
                .{ .switch_screen = pane.visible_screen },
                .erase_and_home,
                .{ .replay = visible },
                .trim_trailing_blanks,
            }) |op| {
                ops[len] = op;
                len += 1;
            }

            try self.paneOps(pane, ops[0..len]);
        }

        if (history != null) {
            // Anything asked for before is measured against the history
            // this replaced. The display asks again from the new one.
            pane.older_wanted = null;
            pane.history_reads +%= 1;

            // A drift re-read is remembered, to tell drifting again
            // right after it. Any other read starts over.
            if (pane.drift_reread) {
                pane.drift_reread = false;
                pane.drift_read = pane.history_reads;
            } else {
                pane.drift_read = null;
                pane.older_off = false;
            }

            // Told after the read's own ops, so whatever the display was
            // holding back for it finds all of it there.
            if (pane.read_all) {
                pane.read_all = false;
                try self.paneOps(pane, &.{.history_complete});
            }

            pane.full_reads -|= 1;
            try self.updatePaneStatus(pane);
        }
    }

    /// A capture's payload decoded into bytes for the terminal. Owned.
    ///
    /// The captures ask tmux to escape everything non-printable so that
    /// no raw ESC ever reaches the DCS carrying control mode, so the
    /// escape sequences `-e` asked for arrive as text and have to be
    /// turned back into bytes here. Decoding never grows the input, so
    /// the reply's own length is enough room.
    fn decodeCapture(self: *Viewer, content: []const u8) Allocator.Error![]u8 {
        const buf = try self.alloc.alloc(u8, content.len);
        errdefer self.alloc.free(buf);
        const len = control.unescape(buf, content).len;
        return try self.alloc.realloc(buf, len);
    }

    /// Tell the pane's display how current it is, if that changed. See
    /// `sinkpkg.PaneStatus`.
    fn updatePaneStatus(self: *Viewer, pane: *Pane) !void {
        // A pause is over once every read queued for the pane has been
        // applied, the one queued to recover it being the last.
        if (pane.full_reads == 0) pane.paused = false;

        const status: sinkpkg.PaneStatus = if (pane.paused)
            .catching_up
        else if (pane.full_reads > 0)
            .loading_history
        else
            .live;
        if (status == pane.status) return;
        pane.status = status;
        try self.paneOps(pane, &.{.{ .pane_status = status }});
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr.*;

        // Split into the pane's output and what was wrapped for the
        // terminal outside tmux, in order. The runs point into `data` and
        // constants, which outlive the call. Almost all output is the
        // pane's own, which comes back as one run of `data` whatever
        // escape sequences are in it, so the list nearly always holds a
        // single op and is kept off the heap.
        var stack = std.heap.stackFallback(8 * @sizeOf(sinkpkg.Op), self.alloc);
        const alloc = stack.get();
        var ops: OpCollector = .{ .alloc = alloc };
        defer ops.list.deinit(alloc);
        try pane.passthrough.feed(data, &ops);
        if (ops.list.items.len > 0) try self.paneOps(pane, ops.list.items);
        try self.hideOutput(id, pane);

        // A server that cannot tell us about alerts by subscription is
        // asked whenever something may have set one. Not before we know
        // which kind of server this is.
        if (self.tmux_version.len > 0 and !self.canSubscribe()) {
            const window = self.windowForPane(id) orelse return;
            if (self.current_window_id != window.id) try self.requestAlerts();
        }
    }

    /// Turns the runs `passthrough.Unwrapper` hands out into ops.
    const OpCollector = struct {
        alloc: Allocator,
        list: std.ArrayList(sinkpkg.Op) = .empty,

        pub fn emit(
            self: *OpCollector,
            kind: passthrough.Kind,
            bytes: []const u8,
        ) Allocator.Error!void {
            try self.list.append(self.alloc, switch (kind) {
                .pane => .{ .bytes = bytes },
                .passthrough => .{ .passthrough = bytes },
            });
        }
    };

    /// Convert a tmux layout dimension into a terminal cell count. tmux
    /// gives us a usize but our terminals are limited to CellCountInt, so
    /// clamp instead of failing: a layout this large is nonsense, and it
    /// isn't worth tearing down the session over.
    fn layoutCellCount(v: usize) size.CellCountInt {
        return std.math.cast(size.CellCountInt, v) orelse max: {
            log.warn("layout dimension too large, clamping value={}", .{v});
            break :max std.math.maxInt(size.CellCountInt);
        };
    }

    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        panes_old: *PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                const cols = layoutCellCount(layout.width);
                const rows = layoutCellCount(layout.height);

                // If we already have this pane, it is already initialized
                // so just copy it over. It may have been resized by the
                // layout change that brought us here, though.
                if (panes_old.get(id)) |pane| {
                    // A zero dimension can't be resized to and only shows
                    // up in a malformed layout, so leave the pane alone
                    // rather than failing the whole sync.
                    if (cols > 0 and rows > 0 and
                        (pane.terminal.cols != cols or
                            pane.terminal.rows != rows))
                    {
                        // The size this layout is replacing. A report of
                        // it still in flight was computed against the old
                        // layout and must not complete a sibling's fresh
                        // set. See `Pane.stale_size` and `nextResize`.
                        //
                        // Unless this is tmux granting the size we last
                        // asked for: the surface asked because it is
                        // already that size, so it owes no report that
                        // would clear the hold, and the hold would then
                        // swallow the next honest request for the old
                        // size -- however much later it comes.
                        const granted = if (pane.last_resize_sent) |sent|
                            sent.cols == cols and sent.rows == rows
                        else
                            false;
                        pane.stale_size = if (granted) null else .{
                            .cols = pane.terminal.cols,
                            .rows = pane.terminal.rows,
                        };

                        try pane.terminal.resize(gpa_alloc, .{
                            .cols = cols,
                            .rows = rows,
                        });
                        pane.reread = true;

                        // Whatever we last asked for, this is the answer,
                        // so forget the request. Leaving it would let a
                        // stale one shrink the window back through
                        // `composeLayoutSize` if a sibling resizes before
                        // this pane's surface has caught up.
                        //
                        // `last_resize_sent` deliberately survives this.
                        // It is what stops us asking the same question
                        // again once tmux has answered it.
                        pane.last_resize_request = null;

                        // Anything mirroring this pane has to resize too.
                        // A consumer that owns a surface should route this
                        // through its surface resize path.
                        if (pane.sink) |s| s.send(&.{.{ .resize = .{
                            .cols = cols,
                            .rows = rows,
                        } }});
                    }

                    gop.value_ptr.* = pane;
                    break :pane;
                }

                gop.value_ptr.* = try Pane.create(io, gpa_alloc, cols, rows);
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning the actions that send them.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        commands: []const Command,
    ) Allocator.Error!void {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        try self.queueCommands(commands);
        self.state = .command_queue;
        try self.flushCommands(arena_alloc, actions);
    }

    /// How many lines of history a read from scratch takes, or null for
    /// all of it: the newest chunk if history is read on demand, never
    /// more than the limit.
    fn historyReadLines(self: *const Viewer) ?u32 {
        const chunk = self.history_chunk orelse return self.history_limit;
        const limit = self.history_limit orelse return chunk;
        return @min(chunk, limit);
    }

    /// Append an action sending each queued command that has not been
    /// sent yet. See `command_queue` for why they need not wait for each
    /// other.
    fn flushCommands(
        self: *Viewer,
        alloc: Allocator,
        actions: *std.ArrayList(Action),
    ) Allocator.Error!void {
        var it = self.command_queue.iterator(.forward);
        var i: usize = 0;
        while (it.next()) |command| : (i += 1) {
            if (i < self.commands_sent) continue;

            var builder: std.Io.Writer.Allocating = .init(alloc);
            command.formatCommand(&builder.writer, .{
                .read = self.historyReadLines(),
                .all = self.history_limit,
            }) catch
                return error.OutOfMemory;
            try actions.append(alloc, .{ .command = builder.writer.buffered() });
        }
        self.commands_sent = i;
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything: the caller's
    /// `flushCommands` sends them, which for anything handled inside
    /// `nextCommand` happens automatically on the way out.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    /// tmux ended control mode, with the reason it gave if it gave one.
    fn exited(self: *Viewer, reason: ?[]const u8) []const Action {
        const actions = self.defunct();
        const text = std.mem.trim(u8, reason orelse return actions, " \t\r\n");
        if (text.len == 0) return actions;

        log.info("tmux control mode exited: {s}", .{text});
        self.action_exit = .{
            .{ .notice = .{ .kind = .exit, .text = text } },
            .exit,
        };
        return &self.action_exit;
    }

    /// The connection to tmux broke without the session ending. See
    /// `Input.connection_lost`.
    ///
    /// Said either way, because a session whose windows all vanish
    /// without a reason looks like a crash. With the command that
    /// started it known, it is said as an offer to run that again.
    fn connectionLost(self: *Viewer) []const Action {
        if (self.state == .defunct) return &.{};

        const actions = self.defunct();
        log.info("lost the connection to tmux", .{});
        self.action_exit = .{
            .{ .notice = if (self.reattach_command.len > 0) .{
                .kind = .connection_lost,
                .text = self.reattach_command,
            } else .{
                .kind = .exit,
                .text = "lost the connection to tmux",
            } },
            actions[0],
        };
        return &self.action_exit;
    }

    /// The notice a notification amounts to, if any. Shared by every
    /// state, since tmux can say these at any time.
    fn notificationNotice(n: control.Notification) ?Notice {
        const kind: Notice.Kind, const raw = switch (n) {
            .message => |text| .{ .message, text },
            .config_error => |text| .{ .config_error, text },
            else => return null,
        };
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) return null;
        return .{ .kind = kind, .text = text };
    }

    /// The reply to the command that started control mode, typically
    /// `attach`.
    ///
    /// tmux writes the configuration file's errors into this reply as
    /// `%config-error` lines rather than as notifications of their own:
    /// they are part of what attaching printed. Nothing else we parse
    /// arrives this way, and this reply is otherwise empty for a
    /// successful attach, so these lines are picked out here. Anything
    /// else in an error reply is why the command failed.
    fn startupNotices(
        self: *Viewer,
        content: []const u8,
        is_err: bool,
    ) Allocator.Error![]const Action {
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        _ = arena.reset(.free_all);
        const alloc = arena.allocator();

        var actions: std.ArrayList(Action) = .empty;
        var it = std.mem.splitScalar(u8, content, '\n');
        var error_start: ?usize = null;
        var error_end: usize = 0;
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const prefix = "%config-error ";
            if (std.mem.startsWith(u8, line, prefix)) {
                const text = std.mem.trim(u8, line[prefix.len..], " \t");
                if (text.len > 0) try actions.append(alloc, .{ .notice = .{
                    .kind = .config_error,
                    .text = text,
                } });
                continue;
            }

            if (!is_err or line.len == 0) continue;

            // The rest of an error reply is the error, which is free text
            // and may run over several lines: keep it in one piece.
            const start = @intFromPtr(line.ptr) - @intFromPtr(content.ptr);
            if (error_start == null) error_start = start;
            error_end = start + line.len;
        }

        if (error_start) |start| try actions.append(alloc, .{ .notice = .{
            .kind = .command_error,
            .text = content[start..error_end],
        } });

        return actions.items;
    }

    /// Give up on a session we can no longer follow, while tmux is still
    /// there: a reply we could not make sense of, or memory running out.
    ///
    /// Leaving is the part that matters. Going defunct on our own would
    /// leave tmux attached and the host's pty in control mode, with
    /// nothing on screen and every key typed into the host swallowed, so
    /// the only way out would be closing the host, which ends the client
    /// tmux was running for and, over ssh, the connection with it. A
    /// `detach-client` instead has tmux end control mode, the same way
    /// as `refuseOldTmux`, and the session keeps running.
    fn abandon(self: *Viewer) []const Action {
        _ = self.defunct();
        self.action_abandon = .{
            .{ .notice = .{
                .kind = .exit,
                .text = "lost track of the tmux session; detached, and it is still running",
            } },
            .{ .command = "detach-client\n" },
            .exit,
        };
        return &self.action_abandon;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;

        // Nothing will ever be delivered to a pane again, so say so now.
        // Waiting for the viewer to be torn down would leave anything
        // mirroring a pane believing it is still live.
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane: *Pane = kv.value_ptr.*;
            if (pane.sink) |s| {
                s.close();
                pane.sink = null;
            }
        }

        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: the first `commands_sent` commands in the queue have
    /// been sent to tmux (via `command` actions), and once a call to
    /// `next` returns, that is all of them. The next output is assumed to
    /// be the result of the oldest, except that a `prompt` takes every
    /// output up to and including its marker.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send command actions for every command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture the given pane's history, which is always the primary
    /// screen's. See `Viewer.paneCaptures` for how the three captures
    /// fit together.
    pane_history: usize,

    /// The same, but all of it as far as `Viewer.history_limit` goes,
    /// even when history is read in chunks. See `Input.read_history`.
    pane_history_all: usize,

    /// Capture the given pane's saved grid: its primary screen while it
    /// is in the alternate screen. Fails when it is not.
    pane_saved: usize,

    /// Capture the given pane's grid on display, whichever screen that is.
    pane_visible: usize,

    /// Capture a run of the given pane's history older than its display
    /// has. See `Viewer.nextHistoryWanted`.
    pane_older_history: OlderHistory,

    /// Capture the terminal state of every pane in the session as best
    /// we can. The pane ID(s) are part of the output so we can map it
    /// back to our panes.
    pane_state,

    /// Get the tmux server version, and whether this client is
    /// read-only.
    tmux_version,

    /// Whether this client is read-only, on its own: see
    /// `Viewer.read_only`.
    client_readonly,

    /// Ask tmux to pause a pane rather than let its backlog grow without
    /// bound. The payload is the age in seconds.
    pause_after: u32,

    /// Every window's alerts, for a server too old to subscribe to them.
    /// See `Viewer.requestAlerts`.
    window_alerts,

    /// The layout saved in every window. See `Viewer.Window.saved_layout`.
    saved_layouts,

    /// Every pane's title, one per line after its id. Subscribing tells
    /// us about changes, and this is what a pane was already called: see
    /// `Viewer.syncLayouts`.
    pane_titles,

    /// Every pane's working directory, the same way.
    pane_paths,

    /// Turn the given pane's output back on, or off. Payload is the pane
    /// id. See `Viewer.Options.hidden_output_off_after`.
    pane_output_on: usize,
    pane_output_off: usize,

    /// Ask tmux for the user's other client flags. See
    /// `Viewer.ClientFlags`.
    client_flags: Viewer.ClientFlags,

    /// List the server's sessions. See `Viewer.sessions`.
    list_sessions,

    /// Read a paste buffer, by name (owned), for the clipboard. See
    /// `Viewer.pasteBufferChanged`.
    paste_buffer: []const u8,

    /// Move the session to a window, for the user moving to it here.
    /// A command of its own, not `user`, so that whether one is still
    /// unanswered can be told: see `Viewer.sessionWindowChanged`.
    select_window: usize,

    /// Make a pane its window's active pane. See `select_window`.
    select_pane: SelectPane,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    /// A command of our own that nobody asked for, written out in full,
    /// newline and all. Owned. Unlike `user`, a failure is ours to log,
    /// not the user's to hear about.
    ours: []const u8,

    /// A command line the user typed, and the marker that follows it.
    /// Answered by any number of replies. See `Viewer.nextCommandLine`.
    prompt: *Prompt,

    /// Ask tmux to tell us whenever these formats' values change, for
    /// what it has no notification for. See `Viewer.subscriptionChanged`.
    subscribe: []const Subscription,

    /// A command sent before the session changed, whose reply is still
    /// to come and is of no use to anyone any more. Sends nothing; it is
    /// never queued, only left in place of what was sent.
    orphan,

    /// How many lines of history the reads from scratch take, or null
    /// for all of them. See `formatCommand`.
    pub const SelectPane = struct {
        window_id: usize,
        pane_id: usize,
    };

    pub const HistoryLines = struct {
        /// `pane_history`: the newest chunk, if history is read on
        /// demand. See `Viewer.historyReadLines`.
        read: ?u32,

        /// `pane_history_all`: `Viewer.history_limit`.
        all: ?u32,
    };

    pub const OlderHistory = struct {
        pane_id: usize,

        /// The run of lines, counted back from the screen as tmux does:
        /// 1 is the line just above it. `oldest` is null for everything
        /// up to the top of the history.
        oldest: ?usize,
        newest: usize,

        /// `Pane.history_reads` when it was asked for.
        read: u32,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_history_all,
            .pane_saved,
            .pane_visible,
            .pane_older_history,
            .pane_state,
            .tmux_version,
            .client_readonly,
            .pause_after,
            .subscribe,
            .window_alerts,
            .saved_layouts,
            .pane_titles,
            .pane_paths,
            .pane_output_on,
            .pane_output_off,
            .orphan,
            .client_flags,
            .list_sessions,
            .select_window,
            .select_pane,
            => {},
            .user, .ours, .paste_buffer => |v| alloc.free(v),
            .prompt => |v| v.destroy(alloc),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    ///
    /// `history` is how many lines of history a read from scratch takes,
    /// the one thing about how a command is written that is up to the
    /// user.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
        history: HistoryLines,
    ) std.Io.Writer.Error!void {
        switch (self) {
            // `-f` sets client flags; `pause-after=N` is the one that
            // makes tmux pause a pane rather than kill us for falling
            // behind (tmux server-client.c). Landed in 3.2, so the caller
            // gates on the version before queueing this.
            .pause_after => |seconds| try writer.print(
                "refresh-client -f pause-after={d}\n",
                .{seconds},
            ),

            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            // Nothing to read, but the reply still has to come, in its
            // place, for the history to be cleared exactly as when there
            // is some (`receivedPaneHistory`). A capture cannot ask for
            // no lines at all -- tmux swaps an empty range around into a
            // line -- so this asks for an empty line instead.
            .pane_history, .pane_history_all => |id| {
                const history_limit = switch (self) {
                    .pane_history_all => history.all,
                    else => history.read,
                };
                if (history_limit == 0) try writer.print(
                    "display-message -p -t %{d} ''\n",
                    .{id},
                ) else if (history_limit) |lines| try writer.print(
                    // As below, but from `lines` back from the screen rather
                    // than from the top of the history. A pane with less
                    // history than that gives all of it.
                    "capture-pane -p -e -C -q -S -{d} -E -1 -t %{d}\n",
                    .{ lines, id },
                ) else try writer.print(
                    // -p = output to stdout instead of buffer
                    // -e = output escape sequences for SGR
                    // -C = escape non-printable bytes as octal. Mandatory
                    //   alongside -e: a reply travels inside a %begin/%end
                    //   block, and unlike %output tmux does not escape block
                    //   payloads, so a raw ESC would terminate the DCS that
                    //   carries control mode and drop us out of the session.
                    // -q = quiet, don't error on a bad range
                    // -S - = start at the top of history ("-")
                    // -E -1 = end at the last line of history (1 before the
                    //   visible area is -1).
                    // -t %{d} = target a specific pane ID
                    // (no -a: the saved grid has no history to capture)
                    "capture-pane -p -e -C -q -S - -E -1 -t %{d}\n",
                    .{id},
                );
            },

            .pane_saved => |id| try writer.print(
                // -a = the saved grid, which only exists while the pane
                //   is in the alternate screen and holds the primary
                // (no -q: "no alternate screen" is the answer we want)
                // The rest as above.
                "capture-pane -p -e -C -N -a -t %{d}\n",
                .{id},
            ),

            .pane_visible => |id| try writer.print(
                // The grid on display, as above.
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -C -N -q -t %{d}\n",
                .{id},
            ),

            // As for the history, between the two lines asked for. -q
            // clamps a start past the top of the history to the top.
            .pane_older_history => |req| if (req.oldest) |oldest| try writer.print(
                "capture-pane -p -e -C -q -S -{d} -E -{d} -t %{d}\n",
                .{ oldest, req.newest, req.pane_id },
            ) else try writer.print(
                "capture-pane -p -e -C -q -S - -E -{d} -t %{d}\n",
                .{ req.newest, req.pane_id },
            ),

            // -s = every pane in the session. Without a target,
            //   list-panes lists the panes of the client's current
            //   window alone, and we keep a terminal for every pane of
            //   every window.
            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -s -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            .client_readonly => try writer.writeAll(
                "display-message -p '#{client_readonly}'\n",
            ),

            // One `-B name:what:format` each. tmux checks these once a
            // second and sends only what changed; 3.2 or newer, so the
            // caller gates on the version.
            .subscribe => |subs| {
                try writer.writeAll("refresh-client");
                for (subs) |sub| try writer.print(
                    " -B '{s}:{s}:{s}'",
                    .{ sub.name(), sub.target(), sub.formatString() },
                );
                try writer.writeAll("\n");
            },

            .window_alerts => try writer.writeAll(
                "list-windows -F '#{window_id} " ++ Format.alerts ++ "'\n",
            ),

            .saved_layouts => try writer.writeAll(
                "list-windows -F '#{window_id} #{@ghostty-layout}'\n",
            ),

            // The id first and the rest of the line after it, because a
            // title or a path can hold any character a format delimiter
            // could be. `-s` for every pane in the session, as for
            // `pane_state`.
            .pane_titles => try writer.writeAll(
                "list-panes -s -F '#{pane_id} " ++ Format.pane_title ++ "'\n",
            ),

            .pane_paths => try writer.writeAll(
                "list-panes -s -F '#{pane_id} #{pane_current_path}'\n",
            ),

            // tmux 3.2 or newer, like `subscribe`.
            .pane_output_on => |id| try writer.print(
                "refresh-client -A '%{d}:on'\n",
                .{id},
            ),

            .pane_output_off => |id| try writer.print(
                "refresh-client -A '%{d}:off'\n",
                .{id},
            ),

            // tmux's names for the flags, comma separated (tmux
            // server-client.c, `server_client_set_flags`).
            .client_flags => |flags| {
                try writer.writeAll("refresh-client -f ");
                var sep: []const u8 = "";
                if (flags.active_pane) {
                    try writer.print("{s}active-pane", .{sep});
                    sep = ",";
                }
                if (flags.no_detach_on_destroy) {
                    try writer.print("{s}no-detach-on-destroy", .{sep});
                    sep = ",";
                }
                try writer.writeByte('\n');
            },

            .list_sessions => try writer.writeAll(std.fmt.comptimePrint(
                "list-sessions -F '{s}'\n",
                .{comptime Format.list_sessions.comptimeFormat()},
            )),

            // A buffer is read through a format, not with `show-buffer`,
            // because tmux does not escape a block's payload: a buffer
            // holding an escape sequence -- anything copied from a
            // colourful program -- would arrive raw, and a raw ESC, CAN or
            // SUB ends the DCS that carries control mode. So the format
            // escapes exactly those, in the octal `control.unescape`
            // reads, after the backslash itself so that a literal `\033`
            // in the buffer survives. `%` is escaped too, so that no line
            // of a multi-line buffer can start `%end` and end the block
            // early. ESC, CAN and SUB go into the pattern as themselves:
            // POSIX regexes have no escape for them, and inside single
            // quotes tmux takes every byte literally.
            //
            // `>` and `<` frame the content, since the parser trims the
            // block's trailing newlines and an empty block cannot be told
            // from an empty buffer otherwise. Newlines in the buffer
            // cannot be escaped like the rest: the command has to stay on
            // one line, and tmux's `#{a:}` will not write one either. See
            // `receivedPasteBuffer` for what that costs. The filter picks the buffer
            // and leaves it out if it is too long to read safely (see
            // `Viewer.max_mirrored_buffer_bytes`). Names are restricted to
            // characters that mean nothing in a format before we get here.
            .paste_buffer => |name| try writer.print(
                "list-buffers -f '#{{&&:#{{==:#{{buffer_name}},{s}}},#{{e|<=:#{{buffer_size}},{d}}}}}' -F '>{s}<'\n",
                .{
                    name,
                    Viewer.max_mirrored_buffer_bytes,
                    "#{s/\\\\/\\\\\\\\/;s/%/\\\\045/;s/\x1b/\\\\033/;s/\x18/\\\\030/;s/\x1a/\\\\032/:buffer_full}",
                },
            ),

            .user, .ours => |v| try writer.writeAll(v),
            .select_window => |id| try writer.print("select-window -t @{d}\n", .{id}),
            .select_pane => |v| try writer.print("select-pane -t %{d}\n", .{v.pane_id}),

            .prompt => |v| try writer.print(
                "{s}\ndisplay-message -p '{s}'\n",
                .{ v.line, v.marker },
            ),

            .orphan => unreachable,
        }
    }
};

/// The `refresh-client -B` subscriptions the viewer makes. Their names
/// are per client, so another client subscribing cannot disturb them,
/// and subscribing under a name again replaces the subscription and
/// starts it over: see `Viewer.sessionChanged`.
const Subscription = enum {
    alerts,
    title,
    path,
    window_order,
    status_left,
    status_windows,
    status_right,

    const prefix = "ghostty-";

    fn name(self: Subscription) []const u8 {
        return switch (self) {
            inline else => |tag| prefix ++ @tagName(tag),
        };
    }

    fn fromName(n: []const u8) ?Subscription {
        if (!std.mem.startsWith(u8, n, prefix)) return null;
        return std.meta.stringToEnum(Subscription, n[prefix.len..]);
    }

    /// What the format is about. `@*` is every window of the session and
    /// `%*` every pane, so windows and panes that come later are covered
    /// without asking again. Nothing means the session, whichever one the
    /// client is on, which follows `switch-client` on its own.
    fn target(self: Subscription) []const u8 {
        return switch (self) {
            .alerts => "@*",
            .title, .path => "%*",
            .window_order, .status_left, .status_windows, .status_right => "",
        };
    }

    fn formatString(self: Subscription) []const u8 {
        return switch (self) {
            .alerts => Format.alerts,
            .title => Format.pane_title,
            .path => "#{pane_current_path}",
            .window_order => "#{W:#{window_id} }",

            // `T:` expands the option as a format, and its strftime
            // escapes, as tmux does when it draws the status line.
            .status_left => "#{T:status-left}",
            .status_right => "#{T:status-right}",

            // Each window as tmux would list it, the current one in its
            // own format.
            .status_windows => "#{W:#{T:window-status-format} ,#{T:window-status-current-format} }",
        };
    }
};

/// A command line the user typed, with what its replies have said so far.
const Prompt = struct {
    /// The line, without control characters or surrounding blanks.
    line: []const u8,

    /// `Viewer.command_marker`, copied so that formatting the command
    /// needs nothing else.
    marker: []const u8,

    output: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,

    fn create(
        alloc: Allocator,
        text: []const u8,
        marker: []const u8,
    ) Allocator.Error!*Prompt {
        const self = try alloc.create(Prompt);
        errdefer alloc.destroy(self);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        for (text) |c| {
            if (c < 0x20 or c == 0x7F) continue;
            try line.append(alloc, c);
        }

        const owned = try alloc.dupe(u8, std.mem.trim(u8, line.items, " "));
        errdefer alloc.free(owned);

        self.* = .{
            .line = owned,
            .marker = try alloc.dupe(u8, marker),
        };
        return self;
    }

    /// Add one reply, to the output or the errors as tmux called it.
    fn collect(
        self: *Prompt,
        alloc: Allocator,
        text: []const u8,
        is_err: bool,
    ) Allocator.Error!void {
        if (text.len == 0) return;
        const list = if (is_err) &self.errors else &self.output;
        if (list.items.len > 0) try list.append(alloc, '\n');
        try list.appendSlice(alloc, text);
    }

    fn destroy(self: *Prompt, alloc: Allocator) void {
        alloc.free(self.line);
        alloc.free(self.marker);
        self.output.deinit(alloc);
        self.errors.deinit(alloc);
        alloc.destroy(self);
    }
};

/// Format strings used for commands in our viewer.
/// The parsed `list-panes` line for a single pane, as carried by
/// `sink.Op.pane_state`.
pub const PaneStateData = Format.list_panes.Struct();

const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
            // Keyboard: modifyOtherKeys. Last because it is the newest
            // (tmux 3.5); older servers print nothing for it.
            .pane_key_mode,
        },
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_active,
            .window_width,
            .window_height,
            .window_layout,
            .window_zoomed_flag,
            .window_visible_layout,
            .window_bell_flag,
            .window_activity_flag,
            .window_silence_flag,
            .@"@ghostty-hidden",
            // For a window, this is its active pane.
            .pane_id,
            // Last on purpose: a window name can contain spaces, so it
            // is parsed as the rest of the line.
            .window_name,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        // Last: a path can contain spaces.
        .vars = &.{ .version, .client_readonly, .host, .HOME },
    };

    const list_sessions: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .session_windows,
            .session_attached,
            // Last: it can contain spaces.
            .session_name,
        },
    };

    /// A pane's foreground command and title, as `Viewer.paneName` reads
    /// them: the command is a file name, so it cannot hold the `/`, and
    /// the title is the rest.
    const pane_title = "#{pane_current_command}/#{pane_title}";

    /// A window's alerts, as `Viewer.Alerts.parse` reads them: no
    /// delimiter, since every flag is one character.
    const alerts = "#{window_bell_flag}#{window_activity_flag}#{window_silence_flag}";

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",

    /// If set, the step must send exactly these commands, in this order:
    /// one per entry, each starting with that entry. Empty means the step
    /// must send nothing.
    commands: ?[]const []const u8 = null,

    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.commands) |expected| {
            var i: usize = 0;
            for (actions) |action| {
                if (action != .command) continue;
                try testing.expect(i < expected.len);
                if (!std.mem.startsWith(u8, action.command, expected[i])) {
                    log.warn(
                        "command {} was {s}, expected {s}",
                        .{ i, action.command, expected[i] },
                    );
                    return error.TestUnexpectedCommand;
                }
                i += 1;
            }
            try testing.expectEqual(expected.len, i);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "a lost connection offers the command that started it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .reattach_command = "ssh host -t tmux -CC attach",
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // A session change carries it over: it is about the host, not
        // about the session.
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 2,
            .name = "other",
        } } } },
        .{
            .input = .connection_lost,
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, actions.len);
                    try testing.expectEqual(.connection_lost, actions[0].notice.kind);
                    try testing.expectEqualStrings(
                        "ssh host -t tmux -CC attach",
                        actions[0].notice.text,
                    );
                    try testing.expect(actions[1] == .exit);
                    try testing.expectEqual(.defunct, v.state);
                }
            }).check,
        },
        // Said once.
        .{
            .input = .connection_lost,
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "a lost connection with no command to offer still says so" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{
        .input = .connection_lost,
        .check = (struct {
            fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                try testing.expectEqual(2, actions.len);
                try testing.expectEqual(.exit, actions[0].notice.kind);
                try testing.expect(actions[1] == .exit);
            }
        }).check,
    }});
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);

                    for (actions) |action| switch (action) {
                        .windows => |windows| {
                            // The action must reference viewer-owned state,
                            // not the temporary list used while parsing.
                            try testing.expectEqual(v.windows.items.ptr, windows.ptr);
                            try testing.expectEqual(v.windows.items.len, windows.len);
                            try testing.expectEqual(@as(usize, 0), windows[0].id);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedWindowsAction;
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                    // The old session's six captures, its subscription
                    // and its pane state are still on their way, ahead
                    // of the new session's two commands.
                    try testing.expectEqual(10, v.command_queue.len());
                    try testing.expectEqual(10, v.commands_sent);
                    try testing.expect(v.command_queue.first().?.* == .orphan);
                }
            }).check,
        },
    });

    // Their replies are dropped rather than read as the new list.
    for (0..8) |_| {
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "" } }).len);
    }
    try testing.expectEqual(2, viewer.command_queue.len());

    try testViewer(&viewer, &.{
        // Whether the client is still writable, asked again because
        // `switch-client -r` is a session change too.
        .{ .input = .{ .tmux = .{ .block_end = "0" } }, .commands = &.{} },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Both startup questions go out at once: tmux answers them in
        // order, so neither has to wait for the other.
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .commands = &.{ "display-message", "list-windows" },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } },
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Every capture for both panes, then the pane state, all sent
        // together and answered below in this order.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{.windows},
            .commands = &.{
                "capture-pane -p -e -C -q -S - -E -1 -t %0",
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "capture-pane -p -e -C -q -S - -E -1 -t %1",
                "capture-pane -p -e -C -N -a -t %1",
                "capture-pane -p -e -C -N -q -t %1",
                "refresh-client -B 'ghostty-alerts:@*:#{window_bell_flag}" ++
                    "#{window_activity_flag}#{window_silence_flag}' " ++
                    "-B 'ghostty-title:%*:#{pane_current_command}/#{pane_title}' " ++
                    "-B 'ghostty-path:%*:#{pane_current_path}'\n",
                "list-panes -s -F",
            },
        },
        // pane_history for pane 0 (primary), held until the rest of
        // the pane's read arrives, so it is applied in one go.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqualStrings("Hello, world!", pane.read_history.?);
                    try testing.expectEqual(.loading_history, pane.status);
                }
            }).check,
        },
        // The rest of the captures and the pane state. Neither pane is
        // in the alternate screen, so tmux has no saved grid for either
        // and says so.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } }, .commands = &.{} },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(.live, pane.status);
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    try testing.expectEqual(0, v.commands_sent);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "capture replay decodes escaped escape sequences" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 42,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // One pane, so the first capture is pane_history for pane 0. The
        // captures must ask tmux to escape what it sends: a raw ESC in a
        // block payload would end the control mode DCS.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 80 24 b25d,80x24,0,0,0 0 b25d,80x24,0,0,0 0 0 0 0 %0
                ,
            } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    if (!std.mem.startsWith(u8, command, "capture-pane")) return;
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-C"));
                }
            }).check,
        },
        // The history response, escaped the same way. Held until the
        // rest of the read arrives.
        .{ .input = .{ .tmux = .{ .block_end = "\\033[32mOLD" } } },
        // No saved grid: the pane is on its primary screen.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        // The visible response, as tmux escapes it under `-e -C`.
        .{
            .input = .{ .tmux = .{ .block_end = "\\033[31mRED" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("OLD", str);
                    }
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("RED", str);
                }
            }).check,
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete the capture-pane commands for pane 0, on its primary
        // screen, plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (3
                    // capture-pane), to re-read pane 0, which the split
                    // resized (2 capture-pane), and 1 pane_state, and
                    // nothing else: the session is already subscribed.
                    try testing.expectEqual(6, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not wait for commands already in flight" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes. Its captures
        // go out at once, behind the ones still in flight.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .commands = &.{
                // Pane 0 was resized by the split, so it is read again.
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "capture-pane -p -e -C -q -S - -E -1 -t %2",
                "capture-pane -p -e -C -N -a -t %2",
                "capture-pane -p -e -C -N -q -t %2",
                "list-panes",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // The first pane's four, the subscription, its
                    // re-read, and the new pane's four.
                    try testing.expectEqual(11, v.command_queue.len());
                    try testing.expectEqual(11, v.commands_sent);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete the capture-pane commands for pane 0, which is on
        // its primary screen and so has no saved grid
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete the capture-pane commands for pane 0, which is on
        // its primary screen and so has no saved grid
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - list-windows goes out at once regardless.
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .commands = &.{"list-windows"},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Behind the five already in flight: the captures,
                    // the subscription and the pane state.
                    try testing.expectEqual(6, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] 0 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        // capture-pane -a: pane 0 is on its primary screen, so there
        // is no saved grid
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        // capture-pane pane 0 visible, which is the primary
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        // capture-pane -a: pane 4 is on its primary screen, so there
        // is no saved grid
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        // capture-pane pane 4 visible, which is the primary
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;1;0;0;1;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160;VT10x
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160;VT10x
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        try testing.expect(t.modes.get(.mouse_event_button));
                        try testing.expect(!t.modes.get(.mouse_event_normal));
                        try testing.expect(t.modes.get(.mouse_format_sgr));
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr.*;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });
}

test "tmux output state unsplit CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const pane = try Viewer.Pane.create(testing.io, testing.allocator, 80, 24);
    viewer.panes.put(testing.allocator, 42, pane) catch |err| {
        pane.destroy(testing.allocator);
        return err;
    };

    try viewer.receivedOutput(42, "\x1b[32mX");

    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.*.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}

test "tmux output state split CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const pane = try Viewer.Pane.create(testing.io, testing.allocator, 80, 24);
    viewer.panes.put(testing.allocator, 42, pane) catch |err| {
        pane.destroy(testing.allocator);
        return err;
    };

    try viewer.receivedOutput(42, "\x1b[32");
    try viewer.receivedOutput(42, "mX");

    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.*.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}

test "pane state ignores out of bounds scroll region" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 1 80 24 b25d,80x24,0,0,0 0 b25d,80x24,0,0,0 0 0 0 0 %0",
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // capture-pane history, saved grid (none) and visible
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes with a scroll region bottom far past the screen
        .{
            .input = .{ .tmux = .{
                .block_end = "%0;0;5;1;;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;60000;;",
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    // Verify the line parsed and was applied.
                    try testing.expectEqual(5, t.screens.active.cursor.y);
                    try testing.expectEqual(0, t.scrolling_region.top);
                    try testing.expectEqual(t.rows - 1, t.scrolling_region.bottom);
                }
            }).check,
        },
        // Vertical tabs act as linefeeds and must scroll within the screen.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x0b" ** 30,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const t: *Terminal = &pane.terminal;
                    try testing.expectEqual(t.rows - 1, t.screens.active.cursor.y);
                }
            }).check,
        },
    });
}

test "tmux raw startup selects primary screen" {
    try testRawStartupScreen(false);
}

test "tmux raw startup selects alternate screen" {
    try testRawStartupScreen(true);
}

fn testRawStartupScreen(comptime alternate_on: bool) !void {
    var parser: control.Parser = .{ .buffer = .init(testing.allocator) };

    defer parser.deinit();

    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const input =
        // Initial connection.
        "%begin 1 1 0\n" ++
        "%end 1 1 0\n" ++
        "%session-changed $42 main\n" ++

        // Tmux version response.
        "%begin 2 2 0\n" ++
        "3.5a 0 host\n" ++
        "%end 2 2 0\n" ++

        // Window and pane layout.
        "%begin 3 3 0\n" ++
        "$42 @0 1 80 24 d962,80x24,0,0,42 0 d962,80x24,0,0,42 0 0 0 0 %42\n" ++
        "%end 3 3 0\n" ++

        // History, which is always the primary screen's.
        "%begin 4 4 0\n" ++
        "%end 4 4 0\n" ++

        // `capture-pane -a`, the saved grid. tmux only has one while
        // the pane is in the alternate screen, and it holds the
        // *primary* screen, put aside. Without one, tmux errors.
        (if (alternate_on)
            "%begin 5 5 0\n" ++
                "under\n" ++
                "%end 5 5 0\n"
        else
            "%begin 5 5 0\n" ++
                "no alternate screen\n" ++
                "%error 5 5 0\n") ++

        // Plain `capture-pane`, the grid on display: the alternate
        // screen if the pane is in it, the primary otherwise.
        "%begin 6 6 0\n" ++
        "%end 6 6 0\n" ++

        // The subscription to alerts, titles and working directories.
        "%begin 7 7 0\n" ++
        "%end 7 7 0\n" ++

        // Cursor position and terminal modes.
        "%begin 8 8 0\n" ++
        "%42;0;0;1;block;default;0;" ++
        (if (alternate_on) "1;0;0;" else "0;0;0;") ++
        "0;1;0;0;0;" ++
        "0;0;0;0;0;" ++
        "0;0;0;23;8,16,24,32,40,48,56,64,72;Ext 2\n" ++
        "%end 8 8 0\n" ++

        // Live output after initialization.
        "%output %42 hello\n";

    const expected_commands = [_][]const u8{
        "display-message",
        "list-windows",
        "capture-pane -p -e -C -q -S - -E -1 -t %42\n",
        "capture-pane -p -e -C -N -a -t %42\n",
        "capture-pane -p -e -C -N -q -t %42\n",
        "refresh-client -B",
        "list-panes",
    };

    var command_index: usize = 0;

    for (input) |byte| {
        if (try parser.put(byte)) |notification| {
            const actions = viewer.next(.{ .tmux = notification });

            for (actions) |action| {
                switch (action) {
                    .command => |command| {
                        try testing.expect(command_index < expected_commands.len);
                        const expected = expected_commands[command_index];
                        try testing.expect(
                            std.mem.startsWith(
                                u8,
                                command,
                                expected,
                            ),
                        );
                        command_index += 1;
                    },
                    .windows, .notice, .status, .paste_buffer => {},
                    .exit => {
                        return error.UnexpectedViewerExit;
                    },
                }
            }
        }
    }
    try testing.expectEqual(expected_commands.len, command_index);
    try testing.expectEqual(@as(usize, 42), viewer.session_id);
    try testing.expectEqualStrings("3.5a", viewer.tmux_version);

    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
    try testing.expectEqual(@as(usize, 1), viewer.panes.count());
    try testing.expect(viewer.panes.contains(42));
    try testing.expect(viewer.command_queue.empty());
    const entry = viewer.panes.getEntry(42) orelse
        return error.ExpectedPane42;

    const pane = entry.value_ptr.*;

    const expected_key: ScreenSet.Key =
        if (alternate_on) .alternate else .primary;

    try testing.expectEqual(
        expected_key,
        pane.terminal.screens.active_key,
    );

    const screen = pane.terminal.screens.active;

    const text = try screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("hello", text);

    const other_key: ScreenSet.Key =
        if (alternate_on) .primary else .alternate;

    const other_screen = pane.terminal.screens.get(other_key) orelse
        return error.ExpectedOtherScreen;

    const other_text = try other_screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(other_text);

    // In the alternate screen, the primary is what tmux had put aside.
    try testing.expectEqualStrings(
        if (alternate_on) "under" else "",
        other_text,
    );
}

test "write sends keys to the target pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // One window with a single pane, id 0.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain the capture-pane commands so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // With the queue empty, a write is sent immediately as a hex-encoded
        // send-keys. "hi" is 0x68 0x69.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "hi" } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expectEqualStrings(
                        "send-keys -H -t %0 68 69\n",
                        command,
                    );
                }
            }).check,
        },
    });
}

test "a write does not wait for commands in flight" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // One window with a single pane, id 0. This sends the pane setup
        // commands, a history capture among them, which for a big pane
        // can take a long time to come back.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // A keystroke now is sent now, not after those replies arrive.
        // tmux still runs it after them, in the order it read them.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "x" } },
            .commands = &.{"send-keys -H -t %0 78\n"},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(6, v.command_queue.len());
                    try testing.expectEqual(6, v.commands_sent);
                }
            }).check,
        },
        // The replies then pair with their commands in order, the
        // write's last.
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{ .input = .{ .tmux = .{ .block_end = "" } }, .commands = &.{} },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    try testing.expectEqual(0, v.commands_sent);
                }
            }).check,
        },
    });
}

test "a reply with nothing in flight is ignored" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expect(viewer.command_queue.empty());

    // Nothing is in flight, so this answers nothing: it is ignored, as
    // before, rather than taken as the answer to whatever comes next.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "stray" } }).len);
    try testing.expectEqual(.command_queue, viewer.state);
}

test "write to an unknown pane is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // The version reply. list-windows was sent along with the
        // version query, so this sends nothing.
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Only pane 0 exists.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Pane 7 was never in a layout, so there is nothing to send to.
        // Queueing it would make tmux error on an unknown target.
        .{
            .input = .{ .write = .{ .pane_id = 7, .data = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // An empty write has nothing to send either. Without this guard
        // we would emit a bare `send-keys`, which tmux reads as "send the
        // key this command is bound to".
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "write before startup completes is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // We are still in startup_block: no session, no panes.
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

/// A sink that applies everything it receives to its own terminal, which
/// is what a real consumer does. Init in place: the stream's handler points
/// at `terminal`, so this must not be moved after init.
const MirrorSink = struct {
    alloc: Allocator,
    terminal: Terminal,
    stream: TerminalStream,
    closed: bool = false,

    /// How many ops other than the pane's own output it has been sent,
    /// for tests about what is not sent. Output is left out because how
    /// it is cut up is the passthrough unwrapper's business.
    ops: usize = 0,

    /// Everything that arrived as `.passthrough`, in order.
    passthrough: std.ArrayList(u8) = .empty,

    /// How many times it was told all of the history is in.
    completes: usize = 0,

    /// The `read` of the last older history it refused as drifted.
    drifted: ?u32 = null,

    fn init(
        self: *MirrorSink,
        alloc: Allocator,
        io: std.Io,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) !void {
        try self.initScrollback(alloc, io, cols, rows, 10_000);
    }

    /// With a scrollback limit of its own, as a surface has one.
    fn initScrollback(
        self: *MirrorSink,
        alloc: Allocator,
        io: std.Io,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
        max_scrollback_bytes: ?usize,
    ) !void {
        self.* = .{
            .alloc = alloc,
            .terminal = try .init(io, alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = max_scrollback_bytes,
            }),
            .stream = undefined,
        };
        self.stream = self.terminal.vtStream();
    }

    fn deinit(self: *MirrorSink) void {
        self.passthrough.deinit(self.alloc);
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
    }

    fn sink(self: *MirrorSink) Sink {
        return .{ .ctx = self, .vtable = &.{
            .ops = applyOps,
            .close = markClosed,
        } };
    }

    fn applyOps(ctx: *anyopaque, ops: []const sinkpkg.Op) void {
        const self: *MirrorSink = @ptrCast(@alignCast(ctx));
        for (ops) |op| if (op != .bytes) {
            self.ops += 1;
        };
        for (ops) |op| switch (op) {
            .bytes => |b| self.stream.nextSlice(b),
            .passthrough => |b| self.passthrough.appendSlice(
                self.alloc,
                b,
            ) catch |err| {
                log.warn("mirror sink failed to keep passthrough: {}", .{err});
            },
            .history_complete => self.completes += 1,
            else => sinkpkg.applyOp(
                self.alloc,
                &self.terminal,
                op,
            ) catch |err| switch (err) {
                error.HistoryDrifted => self.drifted = op.older_history.read,
                else => log.warn("mirror sink failed to apply op: {}", .{err}),
            },
        };
    }

    fn markClosed(ctx: *anyopaque) void {
        const self: *MirrorSink = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

/// Assert that two terminals hold the same visible state.
fn expectMirrored(expected: *Terminal, actual: *Terminal) !void {
    try testing.expectEqual(expected.screens.active_key, actual.screens.active_key);
    try testing.expectEqual(expected.cols, actual.cols);
    try testing.expectEqual(expected.rows, actual.rows);

    {
        const want = try expected.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(want);
        const got = try actual.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    // History is the primary screen's alone: the alternate screen has
    // none, and asking it for its history is an error.
    if (expected.screens.get(.primary)) |want_screen| {
        const want = try want_screen.dumpStringAlloc(
            testing.allocator,
            .{ .history = .{} },
        );
        defer testing.allocator.free(want);
        const got = try actual.screens.get(.primary).?.dumpStringAlloc(
            testing.allocator,
            .{ .history = .{} },
        );
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // Both screens, not just the active one. The cursor of the screen
    // that is *not* active is the state a byte stream can never carry,
    // so it is the whole reason the sink sends operations.
    inline for (.{ .primary, .alternate }) |key| {
        const want_screen = expected.screens.get(key);
        const got_screen = actual.screens.get(key);
        try testing.expectEqual(want_screen == null, got_screen == null);

        if (want_screen) |want| {
            const got = got_screen.?;
            try testing.expectEqual(want.cursor.x, got.cursor.x);
            try testing.expectEqual(want.cursor.y, got.cursor.y);
            try testing.expectEqual(
                want.saved_cursor == null,
                got.saved_cursor == null,
            );
            if (want.saved_cursor) |sc| {
                try testing.expectEqual(sc.x, got.saved_cursor.?.x);
                try testing.expectEqual(sc.y, got.saved_cursor.?.y);
            }

            const want_text = try want.dumpStringAlloc(
                testing.allocator,
                .{ .active = .{} },
            );
            defer testing.allocator.free(want_text);
            const got_text = try got.dumpStringAlloc(
                testing.allocator,
                .{ .active = .{} },
            );
            defer testing.allocator.free(got_text);
            try testing.expectEqualStrings(want_text, got_text);
            try testing.expectEqual(
                want.cursor.cursor_style,
                got.cursor.cursor_style,
            );
        }
    }

    try testing.expectEqual(
        expected.scrolling_region.top,
        actual.scrolling_region.top,
    );
    try testing.expectEqual(
        expected.scrolling_region.bottom,
        actual.scrolling_region.bottom,
    );

    inline for (.{
        .cursor_visible,
        .cursor_blinking,
        .insert,
        .wraparound,
        .keypad_keys,
        .cursor_keys,
        .origin,
        .mouse_event_any,
        .mouse_event_button,
        .mouse_event_normal,
        .mouse_event_x10,
        .mouse_format_utf8,
        .mouse_format_sgr,
        .focus_event,
        .bracketed_paste,
    }) |mode| {
        try testing.expectEqual(
            expected.modes.get(mode),
            actual.modes.get(mode),
        );
    }
}

/// Drive a viewer to steady state with a single 83x44 pane (id 0).
fn testSinglePaneSteps() []const TestStep {
    return comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } } },
        // The three capture replies, for a blank pane on its primary
        // screen, then the subscription. pane_state is left for the
        // test to answer.
    } ++ testPrimaryCaptureSteps("", "") ++ testSubscribeSteps());
}

/// The capture replies tmux sends for a pane on its primary screen:
/// its history, the saved-grid capture failing because there is no
/// alternate screen, then what is on display.
fn testPrimaryCaptureSteps(
    comptime history: []const u8,
    comptime visible: []const u8,
) [3]TestStep {
    return .{
        .{ .input = .{ .tmux = .{ .block_end = history } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = visible } } },
    };
}

/// The reply to the subscription a session's first window list queues
/// after its captures, on a server new enough to have them.
fn testSubscribeSteps() [1]TestStep {
    return .{.{ .input = .{ .tmux = .{ .block_end = "" } } }};
}

const two_panes_vertical = "027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]";
const two_panes_horizontal = "1c1b,83x44,0,0{41x44,0,0,0,41x44,42,0,1}";

/// Startup for a two-pane window with the given layout.
///
/// `vertical` stacks panes 0 (83x20) and 1 (83x23) top to bottom;
/// `horizontal` puts panes 0 and 1 (41x44 each) side by side. Either way
/// the divider between them makes the window 83x44.
fn testTwoPaneSteps(comptime layout: []const u8) []const TestStep {
    return comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 " ++ layout ++ " 0 " ++ layout ++ " 0 0 0 0 %0",
        } } },
        // The capture replies for each pane, both blank and on their
        // primary screens, then the subscription.
    } ++ testPrimaryCaptureSteps("", "") ++ testPrimaryCaptureSteps("", "") ++
        testSubscribeSteps());
}

test "pane state maps tmux mouse flags to the right modes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // tmux reports normal tracking only: mouse_standard_flag is set.
        // mouse_any_flag is not requested at all, since it is a roll-up of
        // the three tracking modes rather than a mode of its own.
        //
        //  ...;mouse_all;mouse_button;mouse_standard;utf8;sgr;...
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;1;0;0;0;0;0;39;8,16;VT10x
            ,
        } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    const t: *Terminal = &pane.terminal;

    // MODE_MOUSE_STANDARD is DECSET 1000, which is mouse_event_normal.
    try testing.expect(t.modes.get(.mouse_event_normal));
    try testing.expect(!t.modes.get(.mouse_event_button));
    try testing.expect(!t.modes.get(.mouse_event_any));

    // tmux has no DECSET 9, so nothing can turn x10 on.
    try testing.expect(!t.modes.get(.mouse_event_x10));
}

test "attached sink mirrors the pane terminal" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    // Attach once the pane exists but before any capture reply lands,
    // which is what a caller reacting to the .windows action does.
    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try viewer.attachPane(0, mirror.sink());

    try testViewer(&viewer, &.{
        // The pane is in the alternate screen. History, which is the
        // primary's; then the saved grid, which tmux only has while the
        // alternate screen is up and which holds the primary; then the
        // grid on display, which is the alternate.
        .{ .input = .{ .tmux = .{ .block_end = "scrollback line" } } },
        .{ .input = .{ .tmux = .{ .block_end = "primary line" } } },
        .{ .input = .{ .tmux = .{ .block_end = "alternate line" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // pane_state: on the alternate screen with its cursor at (7,2).
        // The alternate screen's "saved cursor" is where 1049 put the
        // *primary* cursor aside, (5,3). That primary cursor is the
        // case a byte stream cannot express, since bytes only ever
        // reach the active screen.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;7;2;1;bar;;;1;5;3;1;1;0;0;1;0;0;0;0;0;;;1;40;8,16,24;VT10x
            ,
        } } },
        // Then live output, including a sequence split across two
        // notifications so the mirror's parser state is exercised too.
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "hello \x1b[3",
        } } } },
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "1mred",
        } } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;

    // Pin the inactive screen's cursor to a distinctive value first, so
    // the mirror comparison below is not two zeroes agreeing.
    try testing.expectEqual(.alternate, pane.terminal.screens.active_key);
    const primary = pane.terminal.screens.get(.primary).?;
    try testing.expectEqual(5, primary.cursor.x);
    try testing.expectEqual(3, primary.cursor.y);

    // And it is where leaving 1049 will put the primary cursor back.
    try testing.expectEqual(5, primary.saved_cursor.?.x);
    try testing.expectEqual(3, primary.saved_cursor.?.y);
    {
        const str = try primary.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("primary line", str);
    }

    try expectMirrored(&pane.terminal, &mirror.terminal);

    // Sanity: the replay actually did something, so the comparison above
    // is not just two blank terminals agreeing.
    const str = try mirror.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(str);
    try testing.expect(std.mem.indexOf(u8, str, "hello red") != null);
}

test "a pane's passthrough reaches its sink unwrapped and leaves the grid alone" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try viewer.attachPane(0, mirror.sink());

    // A notification wrapped the way Claude Code wraps it, split mid
    // prefix and mid sequence, with text and a cursor move in the
    // wrapper that tmux would never have drawn.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "before\x1bPtm",
        } } } },
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "ux;junk\x1b\x1b[H\x1b\x1b]777;notify;Ti",
        } } } },
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "tle;Body\x1b\x1b\\\x1b\\after",
        } } } },
    });

    try testing.expectEqualStrings(
        "\x1b]777;notify;Title;Body\x1b\\",
        mirror.passthrough.items,
    );

    // Both sides drew the pane's own output and nothing else, and the
    // cursor is where that output left it.
    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    for ([_]*Terminal{ &pane.terminal, &mirror.terminal }) |t| {
        const str = try t.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("beforeafter", str);
        try testing.expectEqual(11, t.screens.active.cursor.x);
        try testing.expectEqual(0, t.screens.active.cursor.y);
    }
}

test "attaching mid passthrough string waits for it to end" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1bPtmux;\x1b\x1b]9;half",
        } } } },
    });

    // Our own parser is at ground, but the sink would get the rest of
    // the OSC without its start.
    try testing.expectError(
        error.PaneMidSequence,
        viewer.attachPane(0, mirror.sink()),
    );

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x07\x1b\\",
        } } } },
    });
    try viewer.attachPane(0, mirror.sink());
}

test "sink is closed when its pane goes away" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testing.expect(!mirror.closed);

    // Switching session resets the viewer, which drops every pane.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 2,
            .name = "other",
        } } } },
    });

    try testing.expect(!viewer.panes.contains(0));
    try testing.expect(mirror.closed);
}

test "resizing a lone pane resizes its window" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    // A fresh pane has asked for nothing yet. `Pane.create` assigns every
    // field by hand into uninitialized memory, so this catches a field
    // that only looks initialized because it has a default.
    try testing.expectEqual(
        null,
        viewer.panes.getEntry(0).?.value_ptr.*.last_resize_request,
    );

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // A pane that is alone fills its window, so sizing the window is
        // the whole job: nothing is queued behind this.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "refresh-client -C @0:100x30\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Drain the reply, so the queue is empty again and a command that
        // is not deduplicated would be sent immediately. Without that,
        // "no action" would prove nothing.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The same size again is not worth a round trip.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // A different size is.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 30 } },
            .contains_command = "refresh-client -C @0:90x30\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Unknown panes and degenerate sizes are dropped.
        .{
            .input = .{ .resize = .{ .pane_id = 9, .cols = 10, .rows = 10 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 0, .rows = 10 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "resizing a split pane sizes both the window and the pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 grows from 83x20 to 90x25. Nothing goes out yet -- see
        // "a split window is not sized until every pane has asked".
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 25 } } },

        // Pane 1 completes the set, so the whole window can go out at
        // once: 90x(25 + 30 + 1), then a command per pane.
        //
        // The window command goes first, because a pane can never grow
        // past its window; tmux runs them in the order sent, so the
        // pane commands find the window already grown.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 90, .rows = 30 } },
            .commands = &.{
                "refresh-client -C @0:90x56\n",
                "resize-pane -t %0 -x 90 -y 25\n",
                "resize-pane -t %1 -x 90 -y 30\n",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(3, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "a side-by-side split composes across the other axis" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_horizontal));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 widens from 41 to 50 and pane 1 keeps its 41, so the
        // window wants 50 + 41 + the divider -- and the height is the
        // taller of the two rather than their sum.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 50, .rows = 44 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 44 } },
            .contains_command = "refresh-client -C @0:92x44\n",
        },
    });
}

test "a split window is not sized until every pane has asked" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The GUI relaid the window out, so both panes will report -- but
        // they report one at a time. Composing a window size from the
        // first report and the second pane's *old* tmux size would ask
        // tmux for a width neither pane wants, and tmux answering that
        // moves the divider, which relays the window out again. Nothing
        // goes out until the pair is complete.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 25 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqual(0, v.command_queue.len());
                }
            }).check,
        },

        // Pane 1 completes the set, so now the window can be composed
        // from what both panes actually want: 90x(25 + 30 + 1).
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 90, .rows = 30 } },
            .contains_command = "refresh-client -C @0:90x56\n",
        },
    });
}

test "a report from the layout tmux just replaced does not complete a set" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // 83 columns holding two panes of 41, the divider spending the 83rd.
    try testViewer(&viewer, testTwoPaneSteps(two_panes_horizontal));

    // The same window relaid out as 40 and 42.
    const relaid = "123b,83x44,0,0{40x44,0,0,0,42x44,41,0,1}";

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux relays the window out. Both panes change size, so both
        // owe a report computed under this layout.
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = relaid,
            .visible_layout = relaid,
            .raw_flags = "*",
        } } } },

        // Both panes were resized, so both are read again: the saved
        // grid (none, they are on the primary screen) and what is on
        // display for each, then the pane state. Answer them all, so
        // the queue says only what the reports below send.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 1's surface reports the 41 columns it computed from the
        // layout that was just replaced: the report was already in
        // flight when the new one arrived. It is a stale echo and must
        // be held rather than recorded.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 44 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane = v.panes.get(1) orelse return error.MissingPane;
                    try testing.expectEqual(null, pane.last_resize_request);
                }
            }).check,
        },

        // Pane 0 reports under the new layout. Recording the stale 41
        // would complete the set here and compose 40 + 1 + 41 = 82 --
        // a window neither layout describes, whose answer would relay
        // the GUI out and start the exchange again. Nothing may go out
        // while pane 1 has not spoken for this layout.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 40, .rows = 44 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqual(0, v.command_queue.len());
                }
            }).check,
        },

        // Pane 1 catches up. The set is now one generation throughout
        // and composes 40 + 1 + 42 = 83 -- the size tmux already has,
        // though we have never said so, so it is sent once and the
        // panes follow behind it.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 42, .rows = 44 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %0 -x 40 -y 44\n",
                "resize-pane -t %1 -x 42 -y 44\n",
            },
        },
    });
}

test "a layout granting what a pane asked for leaves nothing stale" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));

    // Exactly what the two reports below compose: 90x(25 + 30 + 1).
    const granted = "aab4,90x56,0,0[90x25,0,0,0,90x30,0,26,1]";

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The GUI grew the window, and both panes ask for more.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 90, .rows = 25 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 90, .rows = 30 } },
            .contains_command = "refresh-client -C @0:90x56\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux gives the panes exactly what they asked for. Their
        // surfaces are already that size, so they owe no report, and
        // the sizes this layout replaced are nothing that can come back
        // as an echo.
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = granted,
            .visible_layout = granted,
            .raw_flags = "*",
        } } } },

        // Much later, the window goes back to the size it started at
        // -- in a background tab, say, that the user switches to after
        // the group was resized. That is a fresh request, not an echo,
        // and holding it would leave tmux sizing this window wrong for
        // as long as the GUI stays this size.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 20 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 23 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %0 -x 83 -y 20\n",
                "resize-pane -t %1 -x 83 -y 23\n",
            },
        },
    });
}

test "a window is only resized when its own size changes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Each pane asks for the size it already has, which is the first
        // time either has asked for anything. The window is unchanged at
        // 83x44, but we have never told tmux that, so we do.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 20 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 23 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %0 -x 83 -y 20\n",
                "resize-pane -t %1 -x 83 -y 23\n",
            },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // A divider drag: pane 0 hands a row to pane 1. That composes to
        // the same 83x44, so the window is left alone and only the panes
        // are resized. Sizing the window here is what would move the
        // divider back.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 21 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 22 } },
            .commands = &.{
                "resize-pane -t %0 -x 83 -y 21\n",
                "resize-pane -t %1 -x 83 -y 22\n",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "tmux resizing a pane forgets what we asked for" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 25 } } },
    });

    const pane: *Viewer.Pane = viewer.panes.getEntry(0).?.value_ptr.*;
    try testing.expect(pane.last_resize_request != null);

    // tmux answers with a layout that sizes pane 0 differently. That is
    // the answer to our request, so the request is spent: keeping it would
    // let it compose a stale window size for a sibling's resize later.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = "19fb,83x44,0,0[83x30,0,0,0,83x13,0,31,1]",
            .visible_layout = "19fb,83x44,0,0[83x30,0,0,0,83x13,0,31,1]",
            .raw_flags = "*",
        } } } },
    });

    try testing.expectEqual(30, pane.terminal.rows);
    try testing.expectEqual(null, pane.last_resize_request);
}

test "focusing a pane tells tmux, once" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .contains_command = "select-pane -t %1\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Focus can flap several times in one drag or window switch, and
        // tmux runs commands in order, so a repeat would put latency on
        // the user's own keystrokes for nothing.
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },

        // A different pane is a different answer.
        .{
            .input = .{ .select_pane = .{ .pane_id = 0 } },
            .contains_command = "select-pane -t %0\n",
        },
    });
}

test "focus sync converges instead of looping" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Outbound: the user moves into a pane, we tell tmux.
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .contains_command = "select-pane -t %1\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux answers our own command with a notification. Echoing a
        // command back at this is the livelock iTerm2's TmuxController
        // documents, so it has to produce nothing at all.
        .{
            .input = .{ .tmux = .{ .window_pane_changed = .{
                .window_id = 0,
                .pane_id = 1,
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },

        // And the pane it names is now the one we would dedupe against,
        // so the user focusing it again is silent too.
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },

        // Inbound: tmux says it is on the window it is already on.
        // Nothing is new, and nothing is sent back.
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 0,
            } } },
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.windows.items[0].active);
                    try testing.expectEqual(0, v.current_window_id.?);
                }
            }).check,
        },
    });
}

test "a window we do not know is not focused" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The layout that introduces it has not arrived yet. Telling the
        // GUI to focus a window it does not have is worse than waiting.
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 7,
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .windows);
                    }
                    // Recorded even so: it is still where tmux is, and
                    // that is what stops us telling it to go there.
                    try testing.expectEqual(7, v.current_window_id.?);
                }
            }).check,
        },
    });
}

test "a pane we do not have is not selected" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .select_pane = .{ .pane_id = 9 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "a pane tmux moved away from is selected again" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .commands = &.{"select-pane -t %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Already where tmux is: nothing to send.
        .{ .input = .{ .select_pane = .{ .pane_id = 1 } }, .commands = &.{} },

        // A pane closing, or a split, moves tmux's active pane, and it
        // says so. Focus going back to pane 1 is then a move to send.
        .{ .input = .{ .tmux = .{ .window_pane_changed = .{
            .window_id = 0,
            .pane_id = 0,
        } } } },
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .commands = &.{"select-pane -t %1\n"},
        },
    });
}

/// The two-pane vertical layout collapsed to just pane 1, which is what
/// tmux reports as the visible layout while pane 1 is zoomed.
const zoomed_to_pane_1 = "b7de,83x44,0,0,1";

test "moving to another pane of a zoomed window expects the zoom to go" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = two_panes_vertical,
            .visible_layout = zoomed_to_pane_1,
            .raw_flags = "*Z",
        } } } },
        .{ .input = .{ .tmux = .{ .window_pane_changed = .{
            .window_id = 0,
            .pane_id = 1,
        } } } },
    });
    try testing.expectEqual(1, viewer.windows.items[0].zoomed_pane_id.?);

    // tmux unzooms on a `select-pane` without `-Z`, and the GUI did
    // already. The panes' reports from here on are of the unzoomed
    // layout, and must be weighed against it.
    try testViewer(&viewer, &.{.{
        .input = .{ .select_pane = .{ .pane_id = 0 } },
        .commands = &.{"select-pane -t %0\n"},
    }});
    try testing.expectEqual(null, viewer.windows.items[0].zoomed_pane_id);
    try testing.expectEqual(null, viewer.windows.items[0].zoomed_layout);
}

/// Startup for three windows, deliberately at sparse tmux indexes: ids
/// @0, @5 and @9, in that order. Real sessions look like this as soon as
/// a window in the middle is killed.
fn testThreeWindowSteps() []const TestStep {
    return comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            \\$0 @5 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 0 0 0 0 %1
            \\$0 @9 0 83 44 b7df,83x44,0,0,2 0 b7df,83x44,0,0,2 0 0 0 0 %2
            ,
        } } },
        // The capture replies for each pane, the subscription, then
        // pane_state.
    } ++ testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testSubscribeSteps() ++ [_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });
}

test "a window name cannot become a second command" {
    const cases = [_]struct {
        name: []const u8,
        want: []const u8,
        why: []const u8,
    }{
        .{
            .name = "plain",
            .want = "'plain'",
            .why = "the ordinary case",
        },

        // The one that matters most. tmux reads control mode input a
        // line at a time, so a newline ends the command and the rest is
        // read as another -- quotes and all. Dropping it is the only
        // defence; there is no escape for it.
        .{
            .name = "evil\nkill-window -t @1",
            .want = "'evilkill-window -t @1'",
            .why = "a newline would end the command and start a new one",
        },
        .{
            .name = "tab\there\x00and null\x7f",
            .want = "'tabhereand null'",
            .why = "every control byte goes, not just the newline",
        },

        // Format expansion runs after the parser removes the quotes, so
        // single quotes do not stop `#(...)` from starting a shell job.
        .{
            .name = "#(touch /tmp/pwn)",
            .want = "'##(touch /tmp/pwn)'",
            .why = "a format job would run even inside quotes",
        },
        .{
            .name = "#{session_name}",
            .want = "'##{session_name}'",
            .why = "a format variable would expand",
        },

        // Inside single quotes tmux's lexer takes bytes literally, so
        // these need nothing beyond the quoting itself.
        .{
            .name = "a; kill-server",
            .want = "'a; kill-server'",
            .why = "a command separator is literal inside quotes",
        },
        .{
            .name = "$USER `whoami` \\ ~",
            .want = "'$USER `whoami` \\ ~'",
            .why = "expansion characters are literal inside quotes",
        },
        .{
            .name = "};{",
            .want = "'};{'",
            .why = "braces are literal inside quotes",
        },

        // The quote itself: close, escape, reopen.
        .{
            .name = "it's a \"test\"",
            .want = "'it'\\''s a \"test\"'",
            .why = "an embedded quote must not end the quoting",
        },

        // Handled by the `--` the caller writes, but worth pinning that
        // the name itself is not mangled.
        .{
            .name = "-x",
            .want = "'-x'",
            .why = "a leading dash is left alone; `--` is what saves it",
        },
    };

    for (cases) |c| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try Viewer.writeQuotedName(&buf.writer, c.name);
        testing.expectEqualStrings(c.want, buf.written()) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.why});
            return err;
        };
    }
}

test "renaming a window quotes the name and targets the window" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .rename_window = .{
                .pane_id = 0,
                .name = "a name",
            } },
            .contains_command = "rename-window -t @0 -- 'a name'\n",
        },
    });
}

test "clearing a window name gives it back to tmux" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Not `rename-window` with an empty argument: that would pin the
        // window to a blank name, because renaming turns automatic-rename
        // off as a side effect. Clearing the field means "name yourself
        // again", which is that option going back on.
        .{
            .input = .{ .rename_window = .{ .pane_id = 0, .name = "" } },
            .contains_command = "set-option -w -t @0 automatic-rename on\n",
        },
    });
}

test "renaming a pane we do not have is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .rename_window = .{ .pane_id = 9, .name = "x" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "moving a tab swaps with its neighbour in tmux's order" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 is in @0. One to the right is @5 -- the *next window in
        // the list*, not index 1, which does not exist. Arithmetic on
        // tmux's own indexes would target a window that is not there.
        .{
            .input = .{ .move_window = .{ .pane_id = 0, .amount = 1 } },
            .contains_command = "swap-window -d -s @0 -t @5\n",
        },
    });
}

test "a tab at the end stays there" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 is the first window, so there is nothing to its left.
        .{
            .input = .{ .move_window = .{ .pane_id = 0, .amount = -1 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },

        // And past the far end from the last window.
        .{
            .input = .{ .move_window = .{ .pane_id = 2, .amount = 1 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },

        // Further than the list is long is the same answer, not a wrap
        // and not a clamp onto some other window.
        .{
            .input = .{ .move_window = .{ .pane_id = 0, .amount = 99 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                }
            }).check,
        },
    });
}

test "moving a tab two along moves the one between back" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // One swap per place: @0 trades with @5 and then with @9, which
        // leaves @5 @9 @0. A single swap with @9 would leave @9 @5 @0.
        .{
            .input = .{ .move_window = .{ .pane_id = 0, .amount = 2 } },
            .commands = &.{
                "swap-window -d -s @0 -t @5\n",
                "swap-window -d -s @0 -t @9\n",
                "list-windows",
            },
        },
    });
}

test "moving a tab back walks it past each window" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .move_window = .{ .pane_id = 2, .amount = -2 } },
            .commands = &.{
                "swap-window -d -s @9 -t @5\n",
                "swap-window -d -s @9 -t @0\n",
                "list-windows",
            },
        },
    });
}

test "moving a tab asks for the window order again" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .move_window = .{ .pane_id = 0, .amount = 1 } },
            .commands = &.{ "swap-window -d -s @0 -t @5\n", "list-windows" },
        },
        // The swap's empty reply, then the list in its new order, which
        // the GUI hears about in that order.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @5 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 0 0 0 0 %1
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                \\$0 @9 0 83 44 b7df,83x44,0,0,2 0 b7df,83x44,0,0,2 0 0 0 0 %2
                ,
            } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| if (action == .windows) {
                        try testing.expectEqual(3, action.windows.len);
                        try testing.expectEqual(5, action.windows[0].id);
                        try testing.expectEqual(0, action.windows[1].id);
                        try testing.expectEqual(9, action.windows[2].id);
                        return;
                    };
                    return error.TestExpectedWindowsAction;
                }
            }).check,
        },
    });
}

/// Startup for one window of three panes: pane 0 down the left half,
/// and on the right pane 1 above pane 2.
fn testThreePaneSteps() []const TestStep {
    const layout = "5169,83x44,0,0{41x44,0,0,0,41x44,42,0[41x20,42,0,1,41x23,42,21,2]}";
    return comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 " ++ layout ++ " 0 " ++ layout ++ " 0 0 0 0 %0",
        } } },
    } ++ testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testSubscribeSteps() ++ [_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });
}

test "swapping with the previous or next pane is tmux's own" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreePaneSteps());
    try testViewer(&viewer, &.{
        .{
            .input = .{ .swap_pane = .{ .pane_id = 1, .target = .previous } },
            .commands = &.{"swap-pane -U -t %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 1, .target = .next } },
            .commands = &.{"swap-pane -D -t %1\n"},
        },
    });
}

test "swapping in a direction finds the pane on that side" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreePaneSteps());
    try testViewer(&viewer, &.{
        // Two panes share pane 0's right edge. Pane 2 shares more of it.
        // The pane asked about is the target, so tmux makes it active in
        // its new place and focus goes with it.
        .{
            .input = .{ .swap_pane = .{ .pane_id = 0, .target = .right } },
            .commands = &.{"swap-pane -s %2 -t %0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 1, .target = .left } },
            .commands = &.{"swap-pane -s %0 -t %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 1, .target = .down } },
            .commands = &.{"swap-pane -s %2 -t %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 2, .target = .up } },
            .commands = &.{"swap-pane -s %1 -t %2\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Nothing at the edge of the window.
        .{
            .input = .{ .swap_pane = .{ .pane_id = 0, .target = .left } },
            .commands = &.{},
        },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 1, .target = .up } },
            .commands = &.{},
        },
        .{
            .input = .{ .swap_pane = .{ .pane_id = 2, .target = .right } },
            .commands = &.{},
        },
    });
}

test "rotating, breaking and joining panes ask tmux" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreePaneSteps());
    try testViewer(&viewer, &.{
        .{
            .input = .{ .rotate_window = .{ .pane_id = 2, .direction = .next } },
            .commands = &.{"rotate-window -D -t @0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .rotate_window = .{ .pane_id = 2, .direction = .previous } },
            .commands = &.{"rotate-window -U -t @0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .break_pane = .{ .pane_id = 1 } },
            .commands = &.{"break-pane -s %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Dropped on pane 0's left edge, pane 2 goes before it.
        .{
            .input = .{ .move_pane = .{
                .pane_id = 2,
                .target_pane_id = 0,
                .direction = .left,
            } },
            .commands = &.{"join-pane -h -b -s %2 -t %0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .move_pane = .{
                .pane_id = 0,
                .target_pane_id = 1,
                .direction = .down,
            } },
            .commands = &.{"join-pane -v -s %0 -t %1\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Onto itself, or onto a pane we do not have, is nothing.
        .{
            .input = .{ .move_pane = .{
                .pane_id = 1,
                .target_pane_id = 1,
                .direction = .left,
            } },
            .commands = &.{},
        },
        .{
            .input = .{ .move_pane = .{
                .pane_id = 1,
                .target_pane_id = 7,
                .direction = .left,
            } },
            .commands = &.{},
        },
    });
}

test "joining a pane goes to the window either side, not past the ends" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreeWindowSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .join_pane = .{ .pane_id = 0, .window = .next } },
            .commands = &.{"join-pane -h -s %0 -t @5\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .join_pane = .{ .pane_id = 2, .window = .previous } },
            .commands = &.{"join-pane -h -s %2 -t @5\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .join_pane = .{ .pane_id = 0, .window = .previous } },
            .commands = &.{},
        },
        .{
            .input = .{ .join_pane = .{ .pane_id = 2, .window = .next } },
            .commands = &.{},
        },
    });
}

test "a read-only client does not rearrange panes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testThreePaneSteps());
    viewer.read_only = true;

    const inputs = [_]Viewer.Input{
        .{ .swap_pane = .{ .pane_id = 0, .target = .right } },
        .{ .rotate_window = .{ .pane_id = 0, .direction = .next } },
        .{ .break_pane = .{ .pane_id = 0 } },
        .{ .join_pane = .{ .pane_id = 0, .window = .next } },
        .{ .move_pane = .{ .pane_id = 0, .target_pane_id = 1, .direction = .up } },
    };
    for (inputs) |input| {
        const actions = viewer.next(input);
        try testing.expectEqual(1, actions.len);
        try testing.expect(actions[0] == .notice);
        try testing.expect(viewer.command_queue.empty());
    }
}

test "zooming a pane asks tmux rather than deciding here" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .zoom_pane = .{ .pane_id = 1 } },
            .contains_command = "resize-pane -Z -t %1\n",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Nothing is decided locally: the window is zoomed
                    // when tmux says it is, in the layout that answers
                    // this. Setting it here would show the user a zoom
                    // tmux might refuse.
                    try testing.expectEqual(
                        null,
                        v.windows.items[0].zoomed_pane_id,
                    );
                }
            }).check,
        },
    });
}

test "zooming a pane we do not have is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .zoom_pane = .{ .pane_id = 9 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "a zoomed window keeps every pane it has" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{
                .tmux = .{
                    .layout_change = .{
                        .window_id = 0,
                        .layout = two_panes_vertical,
                        // tmux collapses this to the zoomed pane alone.
                        .visible_layout = zoomed_to_pane_1,
                        .raw_flags = "*Z",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(
                        1,
                        v.windows.items[0].zoomed_pane_id.?,
                    );

                    // The assertion this test exists for. The visible
                    // layout names one pane; if it ever drives the pane
                    // diff, the other pane's terminal is destroyed and
                    // unzooming rebuilds it empty.
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(1));
                }
            }).check,
        },

        // Unzoom: same layout, no Z.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = two_panes_vertical,
                .visible_layout = two_panes_vertical,
                .raw_flags = "*",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(
                        null,
                        v.windows.items[0].zoomed_pane_id,
                    );
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
    });
}

test "a window already zoomed when we attach arrives zoomed" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },

        // list-windows, with the zoom flag set. The zoomed pane is read
        // out of the visible layout rather than taken to be the active
        // pane, which this deliberately disagrees with.
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 1 83 44 " ++ two_panes_vertical ++
                    " 1 " ++ zoomed_to_pane_1 ++ " 0 0 0 0 %0",
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(
                        1,
                        v.windows.items[0].zoomed_pane_id.?,
                    );
                    try testing.expectEqual(2, v.panes.count());

                    // The zoomed pane is created at the size tmux has
                    // it, the whole window, and read at that size; the
                    // pane behind it at the size the layout keeps.
                    try expectPaneSize(v, 1, 83, 44);
                    try expectPaneSize(v, 0, 83, 20);
                }
            }).check,
        },
    });
}

fn expectNotPane0(_: *Viewer, command: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, command, "%0") == null);
}

fn expectPaneSize(v: *Viewer, id: usize, cols: usize, rows: usize) !void {
    const pane = v.panes.get(id) orelse return error.MissingPane;
    try testing.expectEqual(cols, pane.terminal.cols);
    try testing.expectEqual(rows, pane.terminal.rows);
}

test "zooming a pane resizes it to the whole window and unzooming back" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 23);
    defer mirror.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try viewer.attachPane(1, mirror.sink());

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux zooms pane 1. Its layout is still the unzoomed one, but
        // tmux really did make the pane the whole window, 83x44, and
        // writes its output for that size. Only what is on display is
        // read again, and only for the pane that changed.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = two_panes_vertical,
                .visible_layout = zoomed_to_pane_1,
                .raw_flags = "*Z",
            } } },
            .contains_command = "capture-pane -p -e -C -N -a -t %1\n",
            .check_command = expectNotPane0,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try expectPaneSize(v, 1, 83, 44);

                    // tmux leaves the panes behind it alone.
                    try expectPaneSize(v, 0, 83, 20);
                }
            }).check,
        },
    });

    // The surface mirroring the pane is resized with it.
    try testing.expectEqual(83, mirror.terminal.cols);
    try testing.expectEqual(44, mirror.terminal.rows);

    try testViewer(&viewer, &.{
        // The pane is read again at its new size: no saved grid, since
        // it is on the primary screen, a blank display, and its state.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Unzoomed, the pane goes back to its share of the layout.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = two_panes_vertical,
                .visible_layout = two_panes_vertical,
                .raw_flags = "*",
            } } },
            .contains_command = "capture-pane -p -e -C -N -a -t %1\n",
            .check_command = expectNotPane0,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(
                        null,
                        v.windows.items[0].zoomed_layout,
                    );
                    try expectPaneSize(v, 1, 83, 23);
                    try expectPaneSize(v, 0, 83, 20);
                }
            }).check,
        },
    });

    try testing.expectEqual(83, mirror.terminal.cols);
    try testing.expectEqual(23, mirror.terminal.rows);
}

test "a zoomed window is sized from the zoomed pane alone" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Both panes ask for the size they have, so tmux is told the
        // window's size.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 20 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 23 } },
            .contains_command = "refresh-client -C @0:83x44\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Pane 0 asks for its size again, alone. That asks for nothing,
        // so it is kept, waiting for company.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 83, .rows = 20 } },
            .commands = &.{},
        },

        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = two_panes_vertical,
            .visible_layout = zoomed_to_pane_1,
            .raw_flags = "*Z",
        } } } },
        // The pane is read again at its new size: no saved grid, since
        // it is on the primary screen, a blank display, and its state.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The pane's surface, zoomed, reports the whole window: the
        // size tmux already made it. With pane 0's request that
        // completes the layout, which composes 83x(20 + 1 + 44) -- a
        // window tmux would grow to, and grow the zoomed pane with it.
        // But the zoomed pane is the window, at the size it already
        // is, so nothing goes out.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 83, .rows = 44 } },
            .commands = &.{},
        },

        // Whatever the hidden pane's surface makes of being hidden is
        // not a size to ask for, now or once the zoom ends.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 10, .rows = 5 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane = v.panes.get(0) orelse return error.MissingPane;
                    try testing.expectEqual(20, pane.last_resize_request.?.rows);
                }
            }).check,
        },

        // The GUI window grows while zoomed. The zoomed pane is the
        // window, so the window is asked to be its size, and nothing
        // else: a lone pane follows its window.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 90, .rows = 50 } },
            .commands = &.{"refresh-client -C @0:90x50\n"},
        },
    });
}

test "only the Z flag means zoomed" {
    const alloc = testing.allocator;

    // '*' is the current-window flag and '-' the last-window one. tmux
    // formats those against the window's first winlink, so they say
    // nothing reliable about this client and must not be read.
    try testing.expectEqual(
        null,
        Viewer.zoomedLayout(alloc, "*-", zoomed_to_pane_1),
    );
    const zoomed = Viewer.zoomedLayout(alloc, "*Z", zoomed_to_pane_1).?;
    try testing.expectEqual(1, zoomed.content.pane);
    try testing.expectEqual(83, zoomed.width);
    try testing.expectEqual(44, zoomed.height);

    // A visible layout we cannot parse is drawn unzoomed rather than
    // ending the session.
    try testing.expectEqual(
        null,
        Viewer.zoomedLayout(alloc, "Z", "not a layout"),
    );
}

test "pause mode is asked for once the version allows it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .pause_after = 30,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },

        // The version reply is what unblocks this: the flag does not
        // exist before 3.2 and we cannot know which we are talking to
        // until tmux says.
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    var found = false;
                    var it = v.command_queue.iterator(.forward);
                    while (it.next()) |c| {
                        if (c.* == .pause_after) {
                            try testing.expectEqual(30, c.pause_after);
                            found = true;
                        }
                    }
                    try testing.expect(found);
                }
            }).check,
        },
    });
}

test "typing takes a window back from another client that resized it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    const answered: TestStep = .{ .input = .{ .tmux = .{ .block_end = "" } } };
    const typed: Viewer.Input = .{ .write = .{ .pane_id = 0, .data = "a" } };
    const ours: Viewer.Input = .{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "a87d,100x30,0,0,0",
        .visible_layout = "a87d,100x30,0,0,0",
        .raw_flags = "*",
    } } };
    const theirs: Viewer.Input = .{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "a25d,80x20,0,0,0",
        .visible_layout = "a25d,80x20,0,0,0",
        .raw_flags = "*",
    } } };

    try testViewer(&viewer, &.{
        answered,
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .commands = &.{"refresh-client -C @0:100x30\n"},
        },
        answered,

        // tmux did as asked: typing is only typing.
        .{ .input = ours },
        .{ .input = typed, .commands = &.{"send-keys"} },
        answered,

        // Another client typed, and the window is its size now. The next
        // key typed here asks for ours again, ahead of itself.
        .{ .input = theirs },
        .{
            .input = typed,
            .commands = &.{ "refresh-client -C @0:100x30\n", "send-keys" },
        },
        answered,
        answered,

        // Once: tmux keeping it at another size is not asked again per key.
        .{ .input = typed, .commands = &.{"send-keys"} },
        answered,
    });
}

test "the session is announced as soon as tmux names it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_tags = &.{.windows},
            .contains_command = "display-message",
        },
    });
    try testing.expectEqualStrings("test", viewer.session_name);
}

test "detaching works before the session is up" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // Still waiting for the attach to answer: nothing to pair a reply
    // with, so it goes out as it is.
    try testViewer(&viewer, &.{
        .{ .input = .detach, .commands = &.{"detach-client\n"} },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .detach, .commands = &.{"detach-client\n"} },
    });
}

test "a reply we cannot read detaches rather than leaving tmux attached" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        // The version query answered with something that is not one.
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .commands = &.{"detach-client\n"},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(3, actions.len);
                    try testing.expectEqual(.exit, actions[0].notice.kind);
                    try testing.expect(actions[2] == .exit);
                    try testing.expectEqual(.defunct, v.state);
                }
            }).check,
        },
        // And detaching again stays possible until tmux has left.
        .{ .input = .detach, .commands = &.{"detach-client\n"} },
    });
}

test "an old tmux is refused with a reason, and detached from" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .pause_after = 30,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },

        // 3.1 lacks what we rely on. Its reply may not even carry every
        // variable we asked for, which must not stop us saying so.
        .{
            .input = .{ .tmux = .{ .block_end = "3.1c 0 host" } },
            .commands = &.{"detach-client\n"},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(3, actions.len);
                    try testing.expectEqual(.unsupported, actions[0].notice.kind);
                    try testing.expect(std.mem.indexOf(
                        u8,
                        actions[0].notice.text,
                        "3.1c",
                    ) != null);
                    try testing.expect(std.mem.indexOf(
                        u8,
                        actions[0].notice.text,
                        "3.2",
                    ) != null);
                    try testing.expect(actions[2] == .exit);
                    try testing.expectEqual(.defunct, v.state);
                }
            }).check,
        },

        // The window list sent alongside the version is not built.
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 %0",
            } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqual(0, v.windows.items.len);
                }
            }).check,
        },
    });
}

test "a tmux version we cannot read is let in" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .pause_after = 30,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },

        // A packager's scheme, not a release we can compare. It is let
        // in, but not trusted with flags it may not have.
        .{
            .input = .{ .tmux = .{ .block_end = "openbsd-7.6 0 host" } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .exit);
                    try testing.expectEqual(.command_queue, v.state);
                    var it = v.command_queue.iterator(.forward);
                    while (it.next()) |c| {
                        try testing.expect(c.* != .pause_after);
                    }
                }
            }).check,
        },
    });
}

test "pause mode is not asked for when it is off" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    var it = v.command_queue.iterator(.forward);
                    while (it.next()) |c| {
                        try testing.expect(c.* != .pause_after);
                    }
                }
            }).check,
        },
    });
}

test "detaching asks tmux to detach this client" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            // No target: this client, which is the one that asked.
            .input = .detach,
            .contains_command = "detach-client\n",
        },
    });
}

test "a size tmux will not give us is not asked for twice" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Ask for a size.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "refresh-client -C @0:100x30\n",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // tmux answers with something else. It is entitled to: a resize
        // is a request, and the layout is the ruling.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a69d,90x40,0,0,0",
                .visible_layout = "a69d,90x40,0,0,0",
                .raw_flags = "*",
            } } },
        },

        // The pane was resized, so it is read again. Answer that.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // The surface has not moved, so it asks for the same size again.
        // Asking tmux again would be asking a question we have already
        // had answered, and since tmux replies to every resize with a
        // layout, doing so is not one wasted round trip but a loop that
        // never ends.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "an old tmux sizes windows the old way" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        // Per-window sizes arrived in tmux 3.4.
        .{ .input = .{ .tmux = .{ .block_end = "3.3a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // `refresh-client -C @id:WxH` does not exist before 3.4, so the
        // window is sized with resize-window instead. It is still a lone
        // pane, so that is the whole job.
        .{
            .input = .{ .resize = .{ .pane_id = 0, .cols = 100, .rows = 30 } },
            .contains_command = "resize-window -x 100 -y 30 -t @0\n",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "tmux version comparison" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const cases = .{
        .{ "3.4", true },
        .{ "3.5a", true },
        .{ "4.0", true },
        .{ "3.10", true },
        .{ "3.3a", false },
        .{ "2.9", false },
        // A git build, on its way to that release.
        .{ "next-3.4", true },
        .{ "next-3.7", true },
        .{ "next-3.3", false },
        // Nothing we can read is nothing we can rely on.
        .{ "next", false },
        .{ "next-", false },
        .{ "master", false },
        .{ "", false },
        .{ "3.x", false },
    };

    inline for (cases) |case| {
        viewer.alloc.free(viewer.tmux_version);
        viewer.tmux_version = try viewer.alloc.dupe(u8, case[0]);
        try testing.expectEqual(case[1], viewer.tmuxVersionAtLeast(3, 4));
    }
}

test "a paused pane is resumed and re-read" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .contains_command = "refresh-client -A '%0:continue'\n",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Resume, then three captures and a pane state: what
                    // tmux discarded while paused is not coming back, so
                    // the pane has to be read again from scratch.
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        // A pause for a pane we do not know is not worth a round trip.
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 9 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
    });
}

test "a paused pane says it is catching up until it is read again" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.get(0).?;
                    try testing.expectEqual(.live, pane.status);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 0 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.get(0).?;
                    try testing.expectEqual(.catching_up, pane.status);
                }
            }).check,
        },
        // The resume, and tmux saying so.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .@"continue" = .{ .pane_id = 0 } } } },
    });

    // Still catching up until the read that recovers the pane is in.
    const read = testPrimaryCaptureSteps("old", "new");
    try testViewer(&viewer, read[0..2]);
    try testing.expectEqual(.catching_up, viewer.panes.get(0).?.status);
    try testViewer(&viewer, read[2..]);
    try testing.expectEqual(.live, viewer.panes.get(0).?.status);
}

test "a lazy attach shows each screen before reading its history" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .lazy_history = true,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 1 83 44 " ++ two_panes_vertical ++
                    " 0 " ++ two_panes_vertical ++ " 0 0 0 0 %0",
            } },
            // Both screens and their state first, then both panes whole,
            // the subscription, and their state again.
            .commands = &.{
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "capture-pane -p -e -C -N -a -t %1",
                "capture-pane -p -e -C -N -q -t %1",
                "list-panes -s -F",
                "capture-pane -p -e -C -q -S - -E -1 -t %0",
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "capture-pane -p -e -C -q -S - -E -1 -t %1",
                "capture-pane -p -e -C -N -a -t %1",
                "capture-pane -p -e -C -N -q -t %1",
                "refresh-client -B",
                "list-panes -s -F",
            },
        },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "screen" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.get(0).?;
                    try testing.expectEqual(.loading_history, pane.status);
                    const str = try pane.terminal.screens.active.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expectEqualStrings("screen", str);
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // The full read replaces the screen read, history and all.
    const first = testPrimaryCaptureSteps("old", "screen");
    try testViewer(&viewer, &first);
    {
        const pane: *Viewer.Pane = viewer.panes.get(0).?;
        try testing.expectEqual(.live, pane.status);
        const screen = pane.terminal.screens.active;
        const history = try screen.dumpStringAlloc(testing.allocator, .{ .history = .{} });
        defer testing.allocator.free(history);
        try testing.expectEqualStrings("old", history);
        const active = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
        defer testing.allocator.free(active);
        try testing.expectEqualStrings("screen", active);
    }
    try testing.expectEqual(.loading_history, viewer.panes.get(1).?.status);

    const second = testPrimaryCaptureSteps("", "");
    try testViewer(&viewer, &second);
    try testViewer(&viewer, &testSubscribeSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try testing.expectEqual(.live, viewer.panes.get(1).?.status);
    try testing.expect(viewer.command_queue.empty());
}

test "a layout change keeps the window name" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .window_renamed = .{
            .id = 0,
            .name = long_window_name,
        } } } },

        // A split, so the new layout allocates more than the old one did
        // and would land on top of a name stored in the same arena.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = two_panes_vertical,
                .visible_layout = two_panes_vertical,
                .raw_flags = "*",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // The name is what the GUI puts in a tab label and a
                    // title bar, and it crosses the C ABI as a pointer, so
                    // it has to outlive the layout it arrived with.
                    try testing.expectEqualStrings(
                        long_window_name,
                        v.windows.items[0].name,
                    );
                }
            }).check,
        },
    });
}

/// Long enough that a layout parsed into the same arena is certain to
/// land on top of it, rather than happening to stop short.
const long_window_name = "a" ** 512;

test "a window rename reaches the GUI without a round trip" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 0,
                .name = "a new name",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings(
                        "a new name",
                        v.windows.items[0].name,
                    );

                    // The GUI hears of it through the window list, which
                    // carries the new name...
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqualStrings(
                        "a new name",
                        actions[0].windows[0].name,
                    );

                    // ...but nothing is asked or queued: the notification
                    // already carried everything a rename changes.
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // The same name again is tmux repeating itself, not news.
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 0,
                .name = "a new name",
            } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // A rename for a window we do not have is not a reason to die.
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 9,
                .name = "nobody",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings(
                        "a new name",
                        v.windows.items[0].name,
                    );
                }
            }).check,
        },
    });
}

test "the session name follows tmux" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testing.expectEqualStrings("test", viewer.session_name);

    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // tmux tells every control client about every session. Someone
        // else's is nothing to us.
        .{
            .input = .{ .tmux = .{ .session_renamed = .{
                .id = 7,
                .name = "elsewhere",
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqualStrings("test", v.session_name);
                }
            }).check,
        },
        // Ours is re-sent with the window list, which is how the GUI
        // learns of it, and costs no round trip.
        .{
            .input = .{ .tmux = .{ .session_renamed = .{
                .id = 1,
                .name = "renamed",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("renamed", v.session_name);
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(1, actions[0].windows.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // A session change names the new session before its windows
        // arrive, so the empty list that starts it already says which.
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqualStrings("second", v.session_name);
                }
            }).check,
        },
    });
}

test "client size is reported to tmux once" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .client_size = .{ .cols = 120, .rows = 40 } },
            .contains_command = "refresh-client -C 120x40\n",
        },
        // Drain the reply so the queue is empty: otherwise "no action"
        // would just mean "queued behind something".
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .client_size = .{ .cols = 120, .rows = 40 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "kill pane asks tmux to kill it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // Drain the pane_state reply so the command queue is empty and
        // our command is sent immediately rather than queued behind it.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 0 } },
            .contains_command = "kill-pane -t %0\n",
        },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 9 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "new inputs are dropped before startup completes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 1, .rows = 1 } } },
        .{ .input = .{ .client_size = .{ .cols = 1, .rows = 1 } } },
        .{ .input = .{ .paste = .{ .pane_id = 0, .data = "x" } } },
        .{
            .input = .{ .kill_pane = .{ .pane_id = 0 } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "attach sizes the sink from the pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // Deliberately the wrong size: attaching has to correct it.
    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 10, 5);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());

    try testing.expectEqual(83, mirror.terminal.cols);
    try testing.expectEqual(44, mirror.terminal.rows);
}

test "attach is refused while the pane is mid-sequence" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    // Leave the pane's parser part way through an SGR sequence.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b[3",
        } } } },
    });
    try testing.expectError(
        error.PaneMidSequence,
        viewer.attachPane(0, mirror.sink()),
    );

    // Once the sequence completes, attaching works.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "1m",
        } } } },
    });
    try viewer.attachPane(0, mirror.sink());
}

test "sinks are closed when the connection ends" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testing.expect(!mirror.closed);

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = null } },
            .contains_tags = &.{.exit},
        },
    });

    try testing.expect(mirror.closed);
}

test "detaching a pane closes its sink" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    viewer.detachPane(0);
    try testing.expect(mirror.closed);

    // Detach is idempotent and unknown panes are fine.
    viewer.detachPane(0);
    viewer.detachPane(1234);

    try testing.expectError(error.UnknownPane, viewer.attachPane(
        1234,
        mirror.sink(),
    ));
}

test "output escape sequence split across notifications" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        // pane_state, alternate_on = 0.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;39;8,16;VT10x
            ,
        } } },

        // A single SGR sequence delivered in two pieces, which is what a
        // pty does whenever a write lands on a buffer boundary. The
        // parser has to remember it is mid-sequence.
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b[3",
        } } } },
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "1mX",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);

                    // With a fresh parser per notification the escape is
                    // lost and the tail is printed literally as "1mX".
                    try testing.expectEqualStrings("X", str);
                }
            }).check,
        },
    });
}

test "pane state restores the active screen" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try testViewer(&viewer, &.{
        // The captures find the pane in the alternate screen, so the
        // last one replayed, of the grid on display, leaves the active
        // screen on alternate.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The subscription.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // By the time of pane_state the pane has left the alternate
        // screen. pane_state is the later word, so it has to switch back.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;39;8,16;VT10x
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(
                        .primary,
                        pane.terminal.screens.active_key,
                    );
                }
            }).check,
        },
    });
}

test "layout dimensions clamp to the cell count limit" {
    const max = std.math.maxInt(size.CellCountInt);
    try testing.expectEqual(80, Viewer.layoutCellCount(80));
    try testing.expectEqual(max, Viewer.layoutCellCount(max));
    try testing.expectEqual(max, Viewer.layoutCellCount(@as(usize, max) + 1));
}

test "layout change resizes a surviving pane" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // One pane filling the window.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(83, pane.terminal.cols);
                    try testing.expectEqual(44, pane.terminal.rows);
                }
            }).check,
        },
        // Drain the capture-pane commands plus pane_state.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Split the window. Pane 0 survives but is now only 22 rows tall.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr.*;
                    try testing.expectEqual(83, pane.terminal.cols);
                    try testing.expectEqual(22, pane.terminal.rows);

                    // The newly added pane is sized from the layout too.
                    const added: *Viewer.Pane = v.panes.getEntry(2).?.value_ptr.*;
                    try testing.expectEqual(83, added.terminal.cols);
                    try testing.expectEqual(21, added.terminal.rows);
                }
            }).check,
        },
    });
}

test "list-windows windows action outlives the parse" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 42,
            .name = "main",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    const windows = for (actions) |action| {
                        if (action == .windows) break action.windows;
                    } else return error.WindowsActionMissing;

                    // The action must point at our own window list. Anything
                    // else is freed by the time we return to the caller.
                    try testing.expectEqual(
                        @intFromPtr(v.windows.items.ptr),
                        @intFromPtr(windows.ptr),
                    );
                    try testing.expectEqual(v.windows.items.len, windows.len);

                    try testing.expectEqual(1, windows.len);
                    try testing.expectEqual(0, windows[0].id);
                    try testing.expectEqual(83, windows[0].width);
                    try testing.expectEqual(44, windows[0].height);
                }
            }).check,
        },
    });
}

/// The notices in a list of actions, in order.
fn testNotices(
    actions: []const Viewer.Action,
    buf: []Viewer.Notice,
) []const Viewer.Notice {
    var n: usize = 0;
    for (actions) |action| switch (action) {
        .notice => |notice| {
            buf[n] = notice;
            n += 1;
        },
        else => {},
    };
    return buf[0..n];
}

test "config errors in the attach reply are reported" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // tmux writes these into the reply to `attach` rather than sending
    // them on their own, exactly like this.
    const actions = viewer.next(.{ .tmux = .{ .block_end =
        \\%config-error /home/me/.tmux.conf:2: unknown command: nope
        \\%config-error /home/me/.tmux.conf:5: invalid option: bogus
    } });

    var buf: [4]Viewer.Notice = undefined;
    const notices = testNotices(actions, &buf);
    try testing.expectEqual(2, notices.len);
    try testing.expectEqual(.config_error, notices[0].kind);
    try testing.expectEqualStrings(
        "/home/me/.tmux.conf:2: unknown command: nope",
        notices[0].text,
    );
    try testing.expectEqualStrings(
        "/home/me/.tmux.conf:5: invalid option: bogus",
        notices[1].text,
    );

    // And startup carries on as if the reply had been empty.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "s" } } },
        .contains_command = "display-message",
    }});
}

test "a failed attach says why" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const actions = viewer.next(.{ .tmux = .{
        .block_err = "can't find session: nope",
    } });
    var buf: [4]Viewer.Notice = undefined;
    const notices = testNotices(actions, &buf);
    try testing.expectEqual(1, notices.len);
    try testing.expectEqual(.command_error, notices[0].kind);
    try testing.expectEqualStrings("can't find session: nope", notices[0].text);
}

test "an empty attach reply has nothing to say" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const actions = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(0, actions.len);
}

test "messages and config errors are reported in any state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var buf: [4]Viewer.Notice = undefined;

    // Before startup...
    {
        const notices = testNotices(
            viewer.next(.{ .tmux = .{ .message = "early" } }),
            &buf,
        );
        try testing.expectEqual(1, notices.len);
        try testing.expectEqual(.message, notices[0].kind);
        try testing.expectEqualStrings("early", notices[0].text);
    }

    // ...and once running.
    try testViewer(&viewer, testSinglePaneSteps());
    {
        const notices = testNotices(
            viewer.next(.{ .tmux = .{ .message = "hello from display" } }),
            &buf,
        );
        try testing.expectEqual(1, notices.len);
        try testing.expectEqual(.message, notices[0].kind);
        try testing.expectEqualStrings("hello from display", notices[0].text);
    }
    {
        const notices = testNotices(
            viewer.next(.{ .tmux = .{ .config_error = "bad.conf:1: oops" } }),
            &buf,
        );
        try testing.expectEqual(1, notices.len);
        try testing.expectEqual(.config_error, notices[0].kind);
    }

    // An empty message is not worth interrupting anyone for.
    try testing.expectEqual(
        0,
        testNotices(viewer.next(.{ .tmux = .{ .message = "" } }), &buf).len,
    );
}

test "a failed user command is reported" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    var buf: [4]Viewer.Notice = undefined;

    // Drain pane_state.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expect(viewer.command_queue.empty());

    try testViewer(&viewer, &.{.{
        .input = .{ .split = .{ .pane_id = 0, .direction = .right } },
        .contains_command = "split-window",
    }});
    const notices = testNotices(
        viewer.next(.{ .tmux = .{ .block_err = "create pane failed: pane too small\n" } }),
        &buf,
    );
    try testing.expectEqual(1, notices.len);
    try testing.expectEqual(.command_error, notices[0].kind);
    try testing.expectEqualStrings("create pane failed: pane too small", notices[0].text);
    try testing.expect(viewer.command_queue.empty());
}

test "an exit with a reason reports the reason, then exits" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    const actions = viewer.next(.{ .tmux = .{ .exit = "too far behind" } });
    try testing.expectEqual(2, actions.len);
    try testing.expectEqual(.exit, actions[0].notice.kind);
    try testing.expectEqualStrings("too far behind", actions[0].notice.text);
    try testing.expect(actions[1] == .exit);
}

test "an exit without a reason only exits" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());

    const actions = viewer.next(.{ .tmux = .{ .exit = null } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
}

test "notifications we do not act on change nothing" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    // Drain pane_state.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });

    const ignored = [_]control.Notification{
        .{ .paste_buffer_changed = .{ .name = "buffer0" } },
        .{ .paste_buffer_deleted = .{ .name = "buffer0" } },
        .{ .pane_mode_changed = .{ .pane_id = 0 } },
        .{ .subscription_changed = .{ .name = "s", .value = "v" } },
        .{ .sessions_changed = {} },
        // Another session's; ours is re-sent with the window list.
        .{ .session_renamed = .{ .id = 3, .name = "renamed" } },
        .{ .client_detached = .{ .client = "/dev/ttys001" } },
        .{ .client_session_changed = .{
            .client = "/dev/ttys001",
            .session_id = 2,
            .name = "other",
        } },
    };
    for (ignored) |n| {
        try testing.expectEqual(0, viewer.next(.{ .tmux = n }).len);
        try testing.expectEqual(.command_queue, viewer.state);
        try testing.expect(viewer.command_queue.empty());
        try testing.expectEqual(1, viewer.panes.count());
    }
}

test "a large write is split into bounded send-keys, in order" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expect(viewer.command_queue.empty());

    // Two full chunks and one byte over, each chunk a different byte so
    // the order is visible.
    const max = Viewer.max_send_keys_bytes;
    var data: [2 * max + 1]u8 = undefined;
    @memset(data[0..max], 'a');
    @memset(data[max .. 2 * max], 'b');
    data[2 * max] = 'c';

    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(testing.allocator);

    // All of them go out at once, in order.
    const actions = viewer.next(.{ .write = .{ .pane_id = 0, .data = &data } });
    var commands: usize = 0;
    {
        for (actions) |action| switch (action) {
            .command => |command| {
                commands += 1;
                const prefix = "send-keys -H -t %0";
                try testing.expect(std.mem.startsWith(u8, command, prefix));
                var it = std.mem.tokenizeScalar(
                    u8,
                    command[prefix.len .. command.len - 1],
                    ' ',
                );
                var keys: usize = 0;
                while (it.next()) |hex| : (keys += 1) {
                    try sent.append(
                        testing.allocator,
                        try std.fmt.parseInt(u8, hex, 16),
                    );
                }
                try testing.expect(keys <= max);
            },
            else => {},
        };
    }

    try testing.expectEqual(3, commands);
    try testing.expectEqualSlices(u8, &data, sent.items);

    // tmux answers each in turn.
    for (0..3) |_| {
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "" } }).len);
    }
    try testing.expect(viewer.command_queue.empty());
}

test "a paste goes through a tmux paste buffer, framed by tmux" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expect(viewer.command_queue.empty());

    const name = &viewer.paste_buffer;
    try testing.expect(std.mem.startsWith(u8, name, "ghostty-paste-"));

    // Everything that means something to tmux's parser inside double
    // quotes, a control byte, a byte that is not UTF-8 on its own, and
    // a leading `-` that must not be read as a flag.
    const actions = viewer.next(.{ .paste = .{
        .pane_id = 0,
        .data = "-a\"b\\c$HOME #{x}\r\x01\xc3",
    } });
    try testing.expectEqual(2, actions.len);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(
            &buf,
            "set-buffer -b {s} -- \"-a\\042b\\134c\\044HOME #{{x}}\\015\\001\\303\"\n",
            .{name},
        ),
        actions[0].command,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(
            &buf,
            "paste-buffer -p -r -d -b {s} -t %0\n",
            .{name},
        ),
        actions[1].command,
    );
}

test "a large paste is set in appended chunks, then pasted once" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });

    const max = Viewer.max_set_buffer_bytes;
    var data: [2 * max + 1]u8 = undefined;
    @memset(data[0..max], 'a');
    @memset(data[max .. 2 * max], 'b');
    data[2 * max] = 'c';

    const actions = viewer.next(.{ .paste = .{ .pane_id = 0, .data = &data } });
    try testing.expectEqual(4, actions.len);

    // Only the first replaces the buffer: something stale in it from a
    // paste that never reached its pane must not survive.
    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(testing.allocator);
    for (actions[0..3], 0..) |action, i| {
        const command = action.command;
        const prefix = if (i == 0) "set-buffer -b " else "set-buffer -a -b ";
        try testing.expect(std.mem.startsWith(u8, command, prefix));
        const open = std.mem.indexOfScalar(u8, command, '"').?;
        try sent.appendSlice(
            testing.allocator,
            command[open + 1 .. command.len - 2],
        );
    }
    try testing.expectEqualSlices(u8, &data, sent.items);
    try testing.expect(std.mem.startsWith(u8, actions[3].command, "paste-buffer "));

    for (0..4) |_| {
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "" } }).len);
    }
    try testing.expect(viewer.command_queue.empty());
}

test "a paste to an unknown pane is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });

    try testing.expectEqual(0, viewer.next(.{ .paste = .{
        .pane_id = 7,
        .data = "x",
    } }).len);
    try testing.expectEqual(0, viewer.next(.{ .paste = .{
        .pane_id = 0,
        .data = "",
    } }).len);
    try testing.expect(viewer.command_queue.empty());
}

test "the active pane comes from the window list" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "s" } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // Pane 1 is active, not the first listed.
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 1 83 44 " ++ two_panes_vertical ++
                    " 0 " ++ two_panes_vertical ++ " 0 0 0 0 %1",
            } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items[0].active_pane_id.?);
                    for (actions) |action| if (action == .windows) {
                        try testing.expectEqual(1, action.windows[0].active_pane_id.?);
                        return;
                    };
                    return error.NoWindowsAction;
                }
            }).check,
        },
    });
}

test "tmux moving the active pane is passed on" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(0, viewer.windows.items[0].active_pane_id.?);

    // Another client, a script, or a pane closing moved it.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .window_pane_changed = .{
            .window_id = 0,
            .pane_id = 1,
        } } },
        .contains_tags = &.{.windows},
        .commands = &.{},
        .check = (struct {
            fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                try testing.expectEqual(1, v.windows.items[0].active_pane_id.?);
            }
        }).check,
    }});

    // The GUI following it focuses pane 1, which tmux already has.
    try testing.expectEqual(0, viewer.next(.{ .select_pane = .{ .pane_id = 1 } }).len);

    // Told again, nothing has changed.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 1,
    } } }).len);
}

test "the echo of our own select is not passed back" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });

    // The user moves to pane 1 then quickly back to pane 0.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .commands = &.{"select-pane -t %1\n"},
        },
        .{
            .input = .{ .select_pane = .{ .pane_id = 0 } },
            .commands = &.{"select-pane -t %0\n"},
        },
    });
    try testing.expectEqual(0, viewer.windows.items[0].active_pane_id.?);

    // Whatever tmux says while they are on their way may be from before
    // they ran. Passing it on would pull the focus to where the user was
    // a moment ago, and the GUI following it would select it again.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 1,
    } } }).len);
    try testing.expectEqual(0, viewer.windows.items[0].active_pane_id.?);

    // Answered. What tmux says now is where they left it, which the GUI
    // already shows.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 0,
    } } }).len);

    // And a change after that is news.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .window_pane_changed = .{
            .window_id = 0,
            .pane_id = 1,
        } } },
        .contains_tags = &.{.windows},
    }});
}

test "a window list while our select is on its way keeps where the user went" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });

    // Asked for before the select, answered after it was sent: it says
    // pane 0, from before the select ran.
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 0 } } });
    try testViewer(&viewer, &.{.{
        .input = .{ .select_pane = .{ .pane_id = 1 } },
        .commands = &.{"select-pane -t %1\n"},
    }});
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 " ++ two_panes_vertical ++
                " 0 " ++ two_panes_vertical ++ " 0 0 0 0 %0",
        } },
        .check = (struct {
            fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                try testing.expectEqual(1, v.windows.items[0].active_pane_id.?);
                for (actions) |action| if (action == .windows) {
                    try testing.expectEqual(1, action.windows[0].active_pane_id.?);
                };
            }
        }).check,
    }});
}

test "a read-only client watches but does not touch the session" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var buf: [4]Viewer.Notice = undefined;

    // Attached with `-r`: the version reply says so, and the user is told
    // once the windows are out, so the notice has a pane to go over.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
    });
    try testing.expectEqual(0, testNotices(
        viewer.next(.{ .tmux = .{ .block_end = "3.5a 1 host" } }),
        &buf,
    ).len);
    try testing.expect(viewer.read_only);
    {
        const actions = viewer.next(.{ .tmux = .{
            .block_end = "$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0",
        } });
        const notices = testNotices(actions, &buf);
        try testing.expectEqual(1, notices.len);
        try testing.expectEqual(.message, notices[0].kind);
        var windows_first = false;
        for (actions) |action| switch (action) {
            .windows => windows_first = true,
            .notice => break,
            else => {},
        };
        try testing.expect(windows_first);
    }
    const second = testPrimaryCaptureSteps("", "");
    try testViewer(&viewer, &second);
    try testViewer(&viewer, &testSubscribeSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try testing.expect(viewer.command_queue.empty());

    // Typing sends nothing, and says why once rather than per key.
    {
        const actions = viewer.next(.{ .write = .{ .pane_id = 0, .data = "x" } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(.command_error, testNotices(actions, &buf)[0].kind);
    }
    try testing.expectEqual(0, viewer.next(.{ .write = .{ .pane_id = 0, .data = "y" } }).len);
    try testing.expectEqual(0, viewer.next(.{ .paste = .{ .pane_id = 0, .data = "z" } }).len);

    // Asking tmux for something says why nothing happened, every time.
    for ([_]Viewer.Input{
        .{ .new_window = .{} },
        .{ .split = .{ .pane_id = 0, .direction = .right } },
        .{ .kill_pane = .{ .pane_id = 0 } },
        .{ .kill_windows = .{ .pane_id = 0, .scope = .this } },
        .{ .zoom_pane = .{ .pane_id = 0 } },
        .{ .rename_window = .{ .pane_id = 0, .name = "x" } },
        .{ .move_window = .{ .pane_id = 0, .amount = 1 } },
    }) |input| {
        const actions = viewer.next(input);
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(.command_error, testNotices(actions, &buf)[0].kind);
    }

    // Layout and focus are not the user's to report, and are dropped
    // quietly.
    try testing.expectEqual(0, viewer.next(.{ .resize = .{
        .pane_id = 0,
        .cols = 40,
        .rows = 20,
    } }).len);
    try testing.expectEqual(0, viewer.next(.{ .select_pane = .{ .pane_id = 0 } }).len);
    try testing.expect(viewer.command_queue.empty());

    // Our size still goes through.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .client_size = .{ .cols = 100, .rows = 30 } },
            .commands = &.{"refresh-client -C 100x30\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // `switch-client -r` again: tmux re-announces the session we are on,
    // and is asked whether the client may write now.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .session_changed = .{ .id = 1, .name = "test" } } },
        .commands = &.{ "display-message -p '#{client_readonly}'", "list-windows" },
    }});
    try testing.expect(viewer.read_only);
    try testing.expectEqual(0, testNotices(
        viewer.next(.{ .tmux = .{ .block_end = "0" } }),
        &buf,
    ).len);
    try testing.expect(!viewer.read_only);
    {
        const actions = viewer.next(.{ .tmux = .{
            .block_end = "$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0",
        } });
        const notices = testNotices(actions, &buf);
        try testing.expectEqual(1, notices.len);
        try testing.expectEqual(.message, notices[0].kind);
    }
    try testViewer(&viewer, &testPrimaryCaptureSteps("", ""));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .write = .{ .pane_id = 0, .data = "x" } },
            .commands = &.{"send-keys -H -t %0 78\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .detach, .commands = &.{"detach-client\n"} },
    });
}

test "a writable client is not told it is writable" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var buf: [4]Viewer.Notice = undefined;
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
    });
    try testing.expectEqual(0, testNotices(
        viewer.next(.{ .tmux = .{ .block_end = "3.5a 0 host" } }),
        &buf,
    ).len);
    const actions = viewer.next(.{ .tmux = .{
        .block_end = "$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0",
    } });
    try testing.expectEqual(0, testNotices(actions, &buf).len);
    try testing.expect(!viewer.read_only);
}

test "a read-only client may still detach" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 1 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0",
        } } },
    });
    try testing.expect(viewer.read_only);
    try testViewer(&viewer, &.{.{ .input = .detach, .commands = &.{"detach-client\n"} }});
}

test "a split names the side the new pane goes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    const cases = .{
        .{ .right, "split-window -h -t %0\n" },
        .{ .left, "split-window -h -b -t %0\n" },
        .{ .down, "split-window -v -t %0\n" },
        .{ .up, "split-window -v -b -t %0\n" },
    };
    inline for (cases) |case| {
        try testViewer(&viewer, &.{
            .{
                .input = .{ .split = .{ .pane_id = 0, .direction = case[0] } },
                .commands = &.{case[1]},
            },
            .{ .input = .{ .tmux = .{ .block_end = "" } } },
        });
    }
}

test "new windows and splits start where the pane they came from is" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    const answered: TestStep = .{ .input = .{ .tmux = .{ .block_end = "" } } };
    const split: Viewer.Input = .{ .split = .{
        .pane_id = 0,
        .direction = .right,
        .inherit_working_directory = true,
    } };
    const new_window: Viewer.Input = .{ .new_window = .{
        .pane_id = 0,
        .inherit_working_directory = true,
    } };

    // Until tmux has said where the pane is, tmux's default it is.
    try testViewer(&viewer, &.{
        .{ .input = split, .commands = &.{"split-window -h -t %0\n"} },
        answered,
        .{ .input = new_window, .commands = &.{"new-window -a -t @0\n"} },
        answered,
    });

    // Quoted, and with `#` doubled, since tmux expands `-c` as a format.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-path", 0, 0, "/home/me/it's #1"), .commands = &.{} },
        .{
            .input = split,
            .commands = &.{"split-window -h -t %0 -c '/home/me/it'\\''s ##1'\n"},
        },
        answered,
        .{
            .input = new_window,
            .commands = &.{"new-window -a -t @0 -c '/home/me/it'\\''s ##1'\n"},
        },
        answered,
    });

    // The pane's own OSC 7 is for its display. What tmux starts a pane
    // in is tmux's path, not a URL.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b]7;file://host/elsewhere\x07",
        } } } },
        .{
            .input = split,
            .commands = &.{"split-window -h -t %0 -c '/home/me/it'\\''s ##1'\n"},
        },
        answered,
    });

    // Not inheriting, or from a pane we do not know, leaves it to tmux.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .split = .{ .pane_id = 0, .direction = .down } },
            .commands = &.{"split-window -v -t %0\n"},
        },
        answered,
        .{
            .input = .{ .new_window = .{ .pane_id = 0 } },
            .commands = &.{"new-window -a -t @0\n"},
        },
        answered,
        .{ .input = .{ .new_window = .{} }, .commands = &.{"new-window -a\n"} },
        answered,
        .{
            .input = .{ .new_window = .{
                .pane_id = 42,
                .inherit_working_directory = true,
            } },
            .commands = &.{"new-window -a\n"},
        },
        answered,
    });

    // A path that could not be sent as it is is not sent at all.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-path", 0, 0, "/tmp/a\x01b"), .commands = &.{} },
        .{ .input = split, .commands = &.{"split-window -h -t %0\n"} },
        answered,
    });
}

/// A `%subscription-changed` for one of our subscriptions, in session 1.
fn testSubscription(
    name: []const u8,
    window_id: ?usize,
    pane_id: ?usize,
    value: []const u8,
) Viewer.Input {
    return .{ .tmux = .{ .subscription_changed = .{
        .name = name,
        .session_id = 1,
        .window_id = window_id,
        .pane_id = pane_id,
        .value = value,
    } } };
}

fn testWindow(v: *Viewer, id: usize) !*Viewer.Window {
    for (v.windows.items) |*w| if (w.id == id) return w;
    return error.TestWindowMissing;
}

test "window alerts follow tmux's subscription" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try testViewer(&viewer, testThreeWindowSteps());

    try testViewer(&viewer, &.{
        // A bell in a window tmux is not on.
        .{
            .input = testSubscription("ghostty-alerts", 5, null, "100"),
            .contains_tags = &.{.windows},
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const w = try testWindow(v, 5);
                    try testing.expect(w.alerts.bell);
                    try testing.expect(!w.alerts.activity);
                    try testing.expect(!w.alerts.silence);
                }
            }).check,
        },
        // The same again is not news.
        .{
            .input = testSubscription("ghostty-alerts", 5, null, "100"),
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Activity in another.
        .{
            .input = testSubscription("ghostty-alerts", 9, null, "010"),
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect((try testWindow(v, 9)).alerts.activity);
                }
            }).check,
        },
        // Neither a value we understand nor a window we know changes
        // anything.
        .{
            .input = testSubscription("ghostty-alerts", 5, null, "1"),
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect((try testWindow(v, 5)).alerts.bell);
                }
            }).check,
        },
        .{
            .input = testSubscription("ghostty-alerts", 77, null, "111"),
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Moving to the window is what clears its alerts in tmux, so it
        // clears them here without waiting to be told.
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 5,
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect((try testWindow(v, 5)).alerts.eql(.{}));
                    try testing.expect((try testWindow(v, 9)).alerts.activity);
                }
            }).check,
        },
    });

    // A value checked against the session we were on before a switch is
    // not about these windows.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .subscription_changed = .{
        .name = "ghostty-alerts",
        .session_id = 4,
        .window_id = 9,
        .value = "000",
    } } }).len);
    try testing.expect((try testWindow(&viewer, 9)).alerts.activity);
}

test "the window list carries alerts" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                \\$0 @5 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 1 0 1 0 %1
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect((try testWindow(v, 0)).alerts.eql(.{}));
                    try testing.expect((try testWindow(v, 5)).alerts.eql(.{
                        .bell = true,
                        .silence = true,
                    }));
                }
            }).check,
        },
    });
}

test "pane titles and working directories reach the pane's display" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try testing.expectEqualStrings("host", viewer.server_host);
    try viewer.attachPane(0, mirror.sink());

    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "vim/vim: notes"), .commands = &.{} },
        .{ .input = testSubscription("ghostty-path", 0, 0, "/home/me/src"), .commands = &.{} },
    });
    try testing.expectEqualStrings("vim: notes", mirror.terminal.getTitle().?);
    try testing.expectEqualStrings("/home/me/src", mirror.terminal.getPwd().?);

    // Nothing is sent for what the pane already has, whether tmux
    // repeats it or the program said it itself first.
    const ops = mirror.ops;
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "vim/vim: notes") },
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "\x1b]2;make\x07",
        } } } },
        .{ .input = testSubscription("ghostty-title", 0, 0, "vim/make") },
        // tmux could not tell where the pane is.
        .{ .input = testSubscription("ghostty-path", 0, 0, "") },
    });
    try testing.expectEqual(ops, mirror.ops);
    try testing.expectEqualStrings("make", mirror.terminal.getTitle().?);
    try testing.expectEqualStrings("/home/me/src", mirror.terminal.getPwd().?);

    // A display attached later is told both straight away.
    var late: MirrorSink = undefined;
    try late.init(testing.allocator, testing.io, 83, 44);
    defer late.deinit();
    try viewer.attachPane(0, late.sink());
    try testing.expectEqualStrings("make", late.terminal.getTitle().?);
    try testing.expectEqualStrings("/home/me/src", late.terminal.getPwd().?);
}

test "a pane is titled as shell integration would title it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    viewer.server_home = try testing.allocator.dupe(u8, "/home/me");
    try viewer.attachPane(0, mirror.sink());

    // At a prompt, the working directory, whatever tmux's default title.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-path", 0, 0, "/home/me/src"), .commands = &.{} },
        .{ .input = testSubscription("ghostty-title", 0, 0, "-zsh/host"), .commands = &.{} },
    });
    try testing.expectEqualStrings("~/src", mirror.terminal.getTitle().?);

    // A program that titles itself as it starts, reported along with it.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "2.1.306/✳ Fix the bug"), .commands = &.{} },
    });
    try testing.expectEqualStrings("✳ Fix the bug", mirror.terminal.getTitle().?);

    // Back at the prompt, the title it left behind is not the shell's,
    // even when it set it on the way out.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "zsh/Goodbye"), .commands = &.{} },
    });
    try testing.expectEqualStrings("~/src", mirror.terminal.getTitle().?);

    // Nor is it the next program's, which does not title itself.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "lazygit/Goodbye"), .commands = &.{} },
    });
    try testing.expectEqualStrings("lazygit", mirror.terminal.getTitle().?);

    // One that titles itself after starting.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "lazygit/repo"), .commands = &.{} },
    });
    try testing.expectEqualStrings("repo", mirror.terminal.getTitle().?);

    // The prompt follows the working directory.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "zsh/repo"), .commands = &.{} },
        .{ .input = testSubscription("ghostty-path", 0, 0, "/srv/a/b/c/d"), .commands = &.{} },
    });
    try testing.expectEqualStrings("…/b/c/d", mirror.terminal.getTitle().?);

    // A title set at the prompt is the shell's own.
    try testViewer(&viewer, &.{
        .{ .input = testSubscription("ghostty-title", 0, 0, "zsh/my prompt"), .commands = &.{} },
    });
    try testing.expectEqualStrings("my prompt", mirror.terminal.getTitle().?);
}

test "shortPath" {
    var buf: [256]u8 = undefined;
    const cases = [_][3][]const u8{
        .{ "/", "/home/me", "/" },
        .{ "/usr/bin", "/home/me", "/usr/bin" },
        .{ "/usr/local/bin", "/home/me", "/usr/local/bin" },
        .{ "/usr/local/bin/x", "/home/me", "…/local/bin/x" },
        .{ "/home/me", "/home/me", "~" },
        .{ "/home/me/a/b", "/home/me", "~/a/b" },
        .{ "/home/me/a/b/c", "/home/me", "…/a/b/c" },
        .{ "/home/meow/a", "/home/me", "/home/meow/a" },
        .{ "/home/me/a", "", "/home/me/a" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[2], Viewer.shortPath(&buf, case[0], case[1]));
    }
}

test "a name tmux reports before the pane is listed waits for it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // A new window, and the subscription reporting its pane before
        // the window list asked for below has been answered.
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 5 } } },
            .commands = &.{"list-windows"},
        },
        .{ .input = testSubscription("ghostty-title", 5, 1, "vim/fresh"), .commands = &.{} },
        .{ .input = testSubscription("ghostty-path", 5, 1, "/tmp"), .commands = &.{} },
        // A pane that never shows up is forgotten with the rest.
        .{ .input = testSubscription("ghostty-title", 6, 8, "gone"), .commands = &.{} },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                \\$0 @5 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 0 0 0 0 %1
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.get(1).?;
                    try testing.expectEqualStrings("fresh", pane.terminal.getTitle().?);
                    try testing.expectEqualStrings("/tmp", pane.terminal.getPwd().?);
                    try testing.expectEqual(0, v.pending_names.count());
                }
            }).check,
        },
    });
}

/// Startup against a tmux whose version cannot be read, which is let in
/// but not trusted with subscriptions (a release older than 3.2, which
/// has none, is turned away): three windows as in `testThreeWindowSteps`,
/// with every reply answered, including the titles and paths it is
/// asked for instead.
fn testOldThreeWindowSteps() []const TestStep {
    return comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "openbsd-7.6 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                \\$0 @5 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 0 0 0 0 %1
                \\$0 @9 0 83 44 b7df,83x44,0,0,2 0 b7df,83x44,0,0,2 0 0 0 0 %2
                ,
            } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(!std.mem.startsWith(u8, command, "refresh-client -B"));
                }
            }).check,
        },
    } ++ testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++ [_]TestStep{
        // pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Titles, one per line after the id, spaces and all.
        .{
            .input = .{ .tmux = .{ .block_end = "%0 a title with spaces\n%1 one\n%2 two" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.get(0).?;
                    try testing.expectEqualStrings(
                        "a title with spaces",
                        pane.terminal.getTitle().?,
                    );
                }
            }).check,
        },
        // Paths, the same way.
        .{
            .input = .{ .tmux = .{ .block_end = "%0 /a b\n%1 /\n%2 /x" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("/a b", v.panes.get(0).?.terminal.getPwd().?);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "an old tmux is asked for alerts after output elsewhere, once at a time" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try testViewer(&viewer, testOldThreeWindowSteps());

    const query = "list-windows -F '#{window_id} #{window_bell_flag}" ++
        "#{window_activity_flag}#{window_silence_flag}'\n";

    try testViewer(&viewer, &.{
        // Output in the window tmux is on sets nothing tmux would flag.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } },
            .commands = &.{},
        },
        // Output elsewhere may have.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 1, .data = "\x07" } } },
            .commands = &.{query},
        },
        // More while that is out is not another query yet...
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 2, .data = "y" } } },
            .commands = &.{},
        },
        // ...but once it is answered, since it may have been missed.
        .{
            .input = .{ .tmux = .{ .block_end = "@0 000\n@5 100\n@9 000" } },
            .contains_tags = &.{.windows},
            .commands = &.{query},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect((try testWindow(v, 5)).alerts.bell);
                }
            }).check,
        },
        // The same answer again changes nothing and asks nothing.
        .{
            .input = .{ .tmux = .{ .block_end = "@0 000\n@5 100\n@9 000" } },
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
    });
}

test "a hidden pane's output is turned off, and back on with a re-read" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .hidden_output_off_after = 30,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = false } }, .commands = &.{} },
        // Hidden, but not for long enough yet.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "a" } } },
            .commands = &.{},
        },
    });

    // As if it had been hidden for a while.
    const pane = viewer.panes.get(0).?;
    pane.hidden_since = pane.hidden_since.?.subDuration(.fromSeconds(31));

    try testViewer(&viewer, &.{
        // Hiding it again does not start the clock over.
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = false } }, .commands = &.{} },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "b" } } },
            .commands = &.{"refresh-client -A '%0:off'\n"},
        },
        // Once is enough. What tmux had sent already is still shown.
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "c" } } },
            .commands = &.{},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // In sight again: on, and read again from the top.
        .{
            .input = .{ .pane_shown = .{ .pane_id = 0, .shown = true } },
            .commands = &.{
                "refresh-client -A '%0:on'\n",
                "capture-pane -p -e -C -q -S - -E -1 -t %0",
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "list-panes -s -F",
            },
        },
        // Shown is shown: nothing more to do.
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = true } }, .commands = &.{} },
    });
}

test "a hidden pane keeps its output unless asked otherwise" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = false } }, .commands = &.{} },
    });
    const pane = viewer.panes.get(0).?;
    pane.hidden_since = pane.hidden_since.?.subDuration(.fromSeconds(3600));
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "a" } } },
            .commands = &.{},
        },
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = true } }, .commands = &.{} },
    });
}

test "a pane turned off is turned back on when the session changes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .hidden_output_off_after = 1,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .pane_shown = .{ .pane_id = 0, .shown = false } } },
    });
    const pane = viewer.panes.get(0).?;
    pane.hidden_since = pane.hidden_since.?.subDuration(.fromSeconds(2));
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "a" } } },
            .commands = &.{"refresh-client -A '%0:off'\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Off is per client, so it outlives the session. The new one
        // does not know, and must not show the pane frozen.
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "other" } } },
            .commands = &.{
                "display-message -p '#{client_readonly}'",
                "list-windows",
                "refresh-client -A '%0:on'\n",
            },
        },
    });
}

test "a typed command line takes every reply up to its marker" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    // Two commands: two replies, and then the marker's.
    {
        const actions = viewer.next(.{ .command_line = .{
            .text = "  list-sessions; display-message -p hi\n",
        } });
        try testing.expectEqual(1, actions.len);
        var want: [128]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(
                &want,
                "list-sessions; display-message -p hi\ndisplay-message -p '{s}'\n",
                .{&viewer.command_marker},
            ),
            actions[0].command,
        );
    }
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "a: 1 windows" } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "" } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "hi" } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = &viewer.command_marker } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(.command_output, actions[0].notice.kind);
        try testing.expectEqualStrings("a: 1 windows\nhi", actions[0].notice.text);
    }
    try testing.expect(viewer.command_queue.empty());

    // A failing one says why, as an error.
    _ = viewer.next(.{ .command_line = .{ .text = "nonsense" } });
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{
        .block_err = "parse error: unknown command: nonsense",
    } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = &viewer.command_marker } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(.command_error, actions[0].notice.kind);
        try testing.expectEqualStrings(
            "parse error: unknown command: nonsense",
            actions[0].notice.text,
        );
    }

    // Nothing to run is nothing sent.
    try testing.expectEqual(0, viewer.next(.{ .command_line = .{ .text = " \n " } }).len);
    try testing.expect(viewer.command_queue.empty());
}

test "a typed command line cannot run a second line" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    const actions = viewer.next(.{ .command_line = .{
        .text = "display-message -p a\nkill-server",
    } });
    try testing.expect(std.mem.startsWith(
        u8,
        actions[0].command,
        "display-message -p akill-server\ndisplay-message -p 'ghostty-done-",
    ));
}

test "a typed command line that switches session is still answered" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    _ = viewer.next(.{ .command_line = .{ .text = "switch-client -t other" } });

    // tmux switches before it has answered the line, let alone the
    // marker after it.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "other" } } },
        .contains_command = "display-message",
    }});

    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = "" } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = &viewer.command_marker } }).len);

    // And the new session's own questions get their own answers: the
    // read-only check, then the window list.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "0" } }, .commands = &.{} },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @3 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{.windows},
        },
    });
    try testing.expectEqual(2, viewer.session_id);
    try testing.expect(!viewer.read_only);
}

test "the window order and status line are watched when asked for" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .follow_window_order = true,
        .status_line = true,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } },
            .commands = &.{
                "refresh-client -B 'ghostty-window_order::#{W:#{window_id} }'\n",
                "refresh-client -B 'ghostty-status_left::#{T:status-left}'\n",
                "refresh-client -B 'ghostty-status_windows::",
                "refresh-client -B 'ghostty-status_right::#{T:status-right}'\n",
            },
        },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    } ++ testPrimaryCaptureSteps("", "") ++ testSubscribeSteps() ++ [_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    }));
    try testing.expect(viewer.command_queue.empty());

    try testViewer(&viewer, &.{
        // The order we have: nothing to do.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "ghostty-window_order",
                .value = "@0 ",
            } } },
            .commands = &.{},
        },

        // Something moved that tmux did not otherwise mention.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "ghostty-window_order",
                .value = "@3 @0 ",
            } } },
            .commands = &.{"list-windows"},
        },

        // Another client's subscription for us is nothing to us.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "theirs",
                .value = "x",
            } } },
            .commands = &.{},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },

        // The status line, without tmux's styles.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "ghostty-status_left",
                .value = "#[fg=green,bold][main]#[default] ",
            } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqualStrings("[main] ", actions[0].status.left);
                    try testing.expectEqualStrings("", actions[0].status.right);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "ghostty-status_right",
                .value = "\"host\" 12:00",
            } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqualStrings("[main] ", actions[0].status.left);
                    try testing.expectEqualStrings("\"host\" 12:00", actions[0].status.right);
                }
            }).check,
        },

        // Only a change is news, styles aside.
        .{
            .input = .{ .tmux = .{ .subscription_changed = .{
                .name = "ghostty-status_left",
                .value = "#[fg=red][main] ",
            } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });

    // A session change keeps what tmux said: it only says it again when
    // it changes.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .session_changed = .{ .id = 2, .name = "two" } } },
    }});
    try testing.expectEqualStrings("[main] ", viewer.status.left);
    try testing.expectEqualStrings("\"host\" 12:00", viewer.status.right);
}

test "a tmux we cannot tell has subscriptions is not asked to watch anything" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .follow_window_order = true,
        .status_line = true,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "openbsd-7.6 0 host" } }, .commands = &.{} },
    });
}

test "hiding a window is kept in tmux and read back" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Set on the window, then the list read again: the list is what
        // tells the GUI.
        .{
            .input = .{ .hide_window = .{ .window_id = 0, .hidden = true } },
            .commands = &.{
                "set-option -w -t @0 @ghostty-hidden 1\n",
                "list-windows",
            },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 1 %0
                ,
            } },
            .contains_tags = &.{.windows},
            // Nothing is read for a pane nobody is shown.
            .commands = &.{},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.windows.items[0].hidden);
                    try testing.expect(v.paneHidden(0));

                    // Its display was told it is gone; the pane is not.
                    const pane = v.panes.get(0).?;
                    try testing.expect(pane.sink == null);
                }
            }).check,
        },

        // Shown again: unset rather than set to 0, and read from scratch
        // once the list says so.
        .{
            .input = .{ .hide_window = .{ .window_id = 0, .hidden = false } },
            .commands = &.{
                "set-option -w -u -t @0 @ghostty-hidden\n",
                "list-windows",
            },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .contains_tags = &.{.windows},
            .commands = &.{
                "capture-pane -p -e -C -q -S - -E -1 -t %0\n",
                "capture-pane -p -e -C -N -a -t %0\n",
                "capture-pane -p -e -C -N -q -t %0\n",
                "list-panes",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.windows.items[0].hidden);
                    try testing.expect(!v.paneHidden(0));
                }
            }).check,
        },
    });
}

test "a window hidden before we attach is not read" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                \\$0 @1 0 83 44 b7de,83x44,0,0,1 0 b7de,83x44,0,0,1 0 0 0 1 %1
                ,
            } },
            .commands = &.{
                "capture-pane -p -e -C -q -S - -E -1 -t %0\n",
                "capture-pane -p -e -C -N -a -t %0\n",
                "capture-pane -p -e -C -N -q -t %0\n",
                "refresh-client -B",
                "list-panes",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Still tracked: tmux has it, and showing it reads it.
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.paneHidden(1));
                    try testing.expect(!v.paneHidden(0));
                }
            }).check,
        },
    });
}

test "hiding a window we do not have is dropped" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .hide_window = .{ .window_id = 7, .hidden = true } },
            .commands = &.{},
        },
    });
}

test "a read-only client may switch sessions but not hide windows" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 1 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } } },
        .{
            .input = .{ .hide_window = .{ .window_id = 0, .hidden = true } },
            .contains_tags = &.{.notice},
            .commands = &.{},
        },
        .{
            .input = .{ .switch_session = .{ .session_id = 2 } },
            .commands = &.{"switch-client -t '$2'\n"},
        },
        .{
            .input = .list_sessions,
            .commands = &.{"list-sessions -F"},
        },
    });
}

test "switching session names it by id" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .switch_session = .{ .session_id = 3 } },
            .commands = &.{"switch-client -t '$3'\n"},
        },
    });
}

test "the session list is read when asked for, and kept current" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Nobody has asked yet, so sessions coming and going is nothing.
        .{ .input = .{ .tmux = .sessions_changed }, .commands = &.{} },

        .{
            .input = .list_sessions,
            .commands = &.{
                "list-sessions -F '#{session_id} #{session_windows} #{session_attached} #{session_name}'\n",
            },
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 1 1 test
                \\$4 3 0 has spaces in it
                ,
            } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.sessions.items.len);
                    try testing.expectEqual(1, v.sessions.items[0].id);
                    try testing.expectEqual(1, v.sessions.items[0].attached);
                    try testing.expectEqual(4, v.sessions.items[1].id);
                    try testing.expectEqual(3, v.sessions.items[1].windows);
                    try testing.expectEqualStrings(
                        "has spaces in it",
                        v.sessions.items[1].name,
                    );
                }
            }).check,
        },

        // Asked for once, followed from then on.
        .{
            .input = .{ .tmux = .sessions_changed },
            .commands = &.{"list-sessions -F"},
        },
        .{
            .input = .{ .tmux = .{ .block_end = "$1 1 1 test" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.sessions.items.len);
                }
            }).check,
        },

        // A session change keeps the list, and reads it again.
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 4,
                .name = "has spaces in it",
            } } },
            .commands = &.{
                "display-message -p '#{client_readonly}'\n",
                "list-windows",
                "list-sessions -F",
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.sessions_wanted);
                    try testing.expectEqual(1, v.sessions.items.len);
                }
            }).check,
        },
    });
}

test "a changed paste buffer is read for the clipboard" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .mirror_paste_buffers = true,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .paste_buffer_changed = .{ .name = "buffer0" } } },
            .commands = &.{
                "list-buffers -f '#{&&:#{==:#{buffer_name},buffer0},#{e|<=:#{buffer_size},196608}}' -F '>#{s/\\\\/\\\\\\\\/;s/%/\\\\045/;s/\x1b/\\\\033/;s/\x18/\\\\030/;s/\x1a/\\\\032/:buffer_full}<'\n",
            },
        },

        // Escaped as the format asks: the ESC, a literal backslash, and
        // a line that would otherwise have ended the block. Through a pty
        // that turns newlines into CRLF; a CR of the buffer's own
        // survives.
        .{
            .input = .{ .tmux = .{
                .block_end = ">red \\033[31mtext\\033[m a\\\\b\r\n\\045end 1 2 1\r\r\n<",
            } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| switch (action) {
                        .paste_buffer => |data| {
                            try testing.expectEqualStrings(
                                "red \x1b[31mtext\x1b[m a\\b\n%end 1 2 1\r\n",
                                data,
                            );
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedPasteBuffer;
                }
            }).check,
        },

        // Our own pastes, and names we would have to escape, are not read.
        .{
            .input = .{ .tmux = .{ .paste_buffer_changed = .{
                .name = "ghostty-paste-0123456789abcdef",
            } } },
            .commands = &.{},
        },
        .{
            .input = .{ .tmux = .{ .paste_buffer_changed = .{ .name = "it's" } } },
            .commands = &.{},
        },

        // Gone before we asked, or too long to ask for: nothing, rather
        // than an empty clipboard.
        .{
            .input = .{ .tmux = .{ .paste_buffer_changed = .{ .name = "buffer1" } } },
            .contains_command = "list-buffers",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .paste_buffer);
                }
            }).check,
        },
    });
}

test "paste buffers are not read unless asked for" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .paste_buffer_changed = .{ .name = "buffer0" } } },
            .commands = &.{},
        },
    });
}

test "client flags are asked for once the version allows it" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .client_flags = .{ .active_pane = true, .no_detach_on_destroy = true },
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } },
            .commands = &.{"refresh-client -f active-pane,no-detach-on-destroy\n"},
        },
    });
}

test "with an active pane of our own, a select is still where we are" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .client_flags = .{ .active_pane = true },
    });
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_vertical));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .select_pane = .{ .pane_id = 1 } },
            .contains_command = "select-pane -t %1\n",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items[0].active_pane_id.?);
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .select_pane = .{ .pane_id = 1 } }, .commands = &.{} },
    });
}

test "history is read only as far back as asked" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_limit = 500,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..3]);
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } },
        .contains_command = "capture-pane -p -e -C -q -S -500 -E -1 -t %0\n",
    }});
}

test "a history limit of zero reads no history" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_limit = 0,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..3]);
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
                ,
            } },
            .commands = &.{
                "display-message -p -t %0 ''\n",
                "capture-pane -p -e -C -N -a -t %0\n",
                "capture-pane -p -e -C -N -q -t %0\n",
                "refresh-client -B",
                "list-panes",
            },
        },
    });

    // The empty answer clears the history like any other.
    try testViewer(&viewer, &testPrimaryCaptureSteps("", "visible"));
    try testViewer(&viewer, &testSubscribeSteps());
}

test "a pane tmux resizes is read again, without breaking a sequence in flight" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.init(testing.allocator, testing.io, 83, 44);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testViewer(&viewer, &.{
        // pane_state, so the queue is empty.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // A colour, then an underline cut off by tmux after "\x1b[4".
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "old\x1b[32m\x1b[4",
        } } } },

        // tmux shrinks the pane, and we ask what it now has on display:
        // ours was resized by our own rules, not tmux's.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a1dd,60x20,0,0,0",
                .visible_layout = "a1dd,60x20,0,0,0",
                .raw_flags = "*",
            } } },
            .commands = &.{
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "list-panes",
            },
        },

        // The answers: no alternate screen, what tmux has on display (in
        // tmux's escaping), and the cursor after it.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "\\033[44mfrom tmux\\033[49m   ",
        } } },
        .{ .input = .{ .tmux = .{
            .block_end = "%0;12;0;1;block;;0;0;0;0;0;1;0;0;0;0;0;0;0;0;0;0;0;19;;",
        } } },

        // The rest of the underline, then text in it.
        .{ .input = .{ .tmux = .{ .output = .{
            .pane_id = 0,
            .data = "mX",
        } } } },
    });

    inline for (.{ &viewer.panes.get(0).?.terminal, &mirror.terminal }) |t| {
        const text = try t.screens.active.dumpStringAlloc(
            testing.allocator,
            .{ .active = .{} },
        );
        defer testing.allocator.free(text);

        // The capture replaced the screen, the underline was not
        // printed as text, its tail took effect, and the colour the
        // program set before the capture is still the one it draws
        // with: the capture's own colours ended with it.
        try testing.expectEqualStrings("from tmux   X", text);
        const screen = t.screens.active;
        const cell = screen.pages.getCell(.{ .active = .{ .x = 12, .y = 0 } }).?;
        const page = cell.node.page();
        const style = page.styles.get(page.memory, cell.cell.style_id);
        try testing.expectEqual(@as(u8, 2), style.fg_color.palette);
        try testing.expect(style.bg_color == .none);
        try testing.expect(style.flags.underline != .none);

        // The capture's styled cells survived, its plain padding did
        // not: the trailing blank after X is empty.
        const blue = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(blue.cell.style_id != 0);
    }
}

test "dragging a divider that leaves one side alone resizes the panes it moved" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // Pane 0 on the left; panes 1 (20 rows) and 2 (23 rows) stacked on
    // the right.
    const layout = "5169,83x44,0,0{41x44,0,0,0,41x44,42,0[41x20,42,0,1,41x23,42,21,2]}";
    try testViewer(&viewer, comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 " ++ layout ++ " 0 " ++ layout ++ " 0 0 0 0 %0",
        } } },
    } ++ testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testSubscribeSteps() ++ [_]TestStep{
        // pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    }));

    try testViewer(&viewer, &.{
        // The divider between 1 and 2 moves down five rows. Pane 1
        // reports first: with 2 still at 23 rows that is a taller
        // window than tmux has, so it waits for 2.
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 25 } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |a| try testing.expect(a != .command);
                }
            }).check,
        },

        // Pane 2 reports. Pane 0 never will -- it did not change -- and
        // the three add up to the window tmux already has, so the two
        // that moved are resized.
        .{
            .input = .{ .resize = .{ .pane_id = 2, .cols = 41, .rows = 18 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %1 -x 41 -y 25\n",
                "resize-pane -t %2 -x 41 -y 18\n",
            },
        },
    });
}

test "panes reporting alone are resized alone only if they fit the window tmux has laid out" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    // Pane 0 on the left; panes 1 (20 rows) and 2 (23 rows) stacked on
    // the right.
    const layout = "5169,83x44,0,0{41x44,0,0,0,41x44,42,0[41x20,42,0,1,41x23,42,21,2]}";
    try testViewer(&viewer, comptime &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        .{ .input = .{ .tmux = .{
            .block_end = "$0 @0 1 83 44 " ++ layout ++ " 0 " ++ layout ++ " 0 0 0 0 %0",
        } } },
    } ++ testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testPrimaryCaptureSteps("", "") ++
        testSubscribeSteps() ++ [_]TestStep{
        // pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    }));

    try testViewer(&viewer, &.{
        // The GUI window changes size and every pane reports.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 50, .rows = 30 } } },
        .{ .input = .{ .resize = .{ .pane_id = 1, .cols = 50, .rows = 14 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 2, .cols = 50, .rows = 15 } },
            .commands = &.{
                "refresh-client -C @0:101x30\n",
                "resize-pane -t %0 -x 50 -y 30\n",
                "resize-pane -t %1 -x 50 -y 14\n",
                "resize-pane -t %2 -x 50 -y 15\n",
            },
        },
    });
    for (0..4) |_| try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});

    // Before tmux lays the window out at that size, panes 1 and 2
    // report sizes that, with pane 0 at the size tmux still has it,
    // add up to the old window. Sent, they would ask tmux for the old
    // size back.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 25 } },
            .commands = &.{},
        },
        .{
            .input = .{ .resize = .{ .pane_id = 2, .cols = 41, .rows = 18 } },
            .commands = &.{},
        },
    });

    // Once it does, a pane narrower than its sibling is not a drag
    // inside the window, however the window's size comes out: it waits
    // for the rest of the panes.
    const resized = "1fd9,101x30,0,0{50x30,0,0,0,50x30,51,0[50x14,51,0,1,50x15,51,15,2]}";
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = resized,
            .visible_layout = resized,
            .raw_flags = "*",
        } } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 30, .rows = 14 } },
            .commands = &.{},
        },
    });

    // And a divider dragged inside the window resizes the panes it
    // moved, and the window is left as it is.
    try testViewer(&viewer, &.{
        .{ .input = .{ .resize = .{ .pane_id = 1, .cols = 50, .rows = 19 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 2, .cols = 50, .rows = 10 } },
            .commands = &.{
                "resize-pane -t %1 -x 50 -y 19\n",
                "resize-pane -t %2 -x 50 -y 10\n",
            },
        },
    });
}

test "a resize re-read behind a full read still in flight leaves the full read whole" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .session_changed = .{
            .id = 1,
            .name = "test",
        } } } },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a 0 host" } } },
        // The window list queues the full read of pane 0: history, saved
        // grid, grid on display.
        .{ .input = .{ .tmux = .{
            .block_end =
            \\$0 @0 1 83 44 b7dd,83x44,0,0,0 0 b7dd,83x44,0,0,0 0 0 0 0 %0
            ,
        } } },

        // tmux resizes the pane before any of that read is answered. Its
        // screens are read again, behind the full read.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a1dd,60x20,0,0,0",
                .visible_layout = "a1dd,60x20,0,0,0",
                .raw_flags = "*",
            } } },
            .commands = &.{
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "list-panes",
            },
        },

        // The full read lands, taken before the resize, and is applied
        // whole: it is the pane's history.
        .{ .input = .{ .tmux = .{ .block_end = "old history" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "old screen" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.get(0).?;
                    try testing.expectEqual(0, pane.full_reads);
                    try testing.expectEqual(.live, pane.status);
                }
            }).check,
        },
        // The subscription and the first pane state.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Then the re-read, taken after the resize: it replaces the
        // screen and leaves the history the full read brought.
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "new screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    const pane = viewer.panes.get(0).?;
    try testing.expectEqual(0, pane.full_reads);
    try testing.expect(viewer.command_queue.empty());

    const screen = pane.terminal.screens.active;
    const active = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(active);
    try testing.expectEqualStrings("new screen", active);

    const all = try screen.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "old history") != null);
    try testing.expect(std.mem.indexOf(u8, all, "old screen") == null);
}

fn expectMirrorHistory(mirror: *MirrorSink, expected: []const u8) !void {
    const text = try mirror.terminal.screens.get(.primary).?.dumpStringAlloc(
        testing.allocator,
        .{ .history = .{} },
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

/// What `history_wanted` asks of the viewer for pane 0.
fn testHistoryWanted(held: usize, all: bool) Viewer.Input {
    return .{ .history_wanted = .{ .pane_id = 0, .held = held, .all = all } };
}

test "history read in chunks reads only the newest chunk from scratch" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..3]);
    try testViewer(&viewer, &.{.{
        .input = testSinglePaneSteps()[3].input,
        .contains_command = "capture-pane -p -e -C -q -S -3 -E -1 -t %0\n",
    }});
}

test "older history is read as the display asks, and goes in above what it has" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.initScrollback(testing.allocator, testing.io, 83, 44, null);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try viewer.attachPane(0, mirror.sink());
    try testViewer(&viewer, &(testPrimaryCaptureSteps("c\r\nd\r\ne", "x") ++
        testSubscribeSteps()));
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try expectMirrorHistory(&mirror, "c\nd\ne");

    try testViewer(&viewer, &.{
        // Three lines held, so the next three, through the oldest of
        // ours for the overlap.
        .{
            .input = testHistoryWanted(3, false),
            .commands = &.{"capture-pane -p -e -C -q -S -6 -E -3 -t %0\n"},
        },

        // Asked again while that is on its way: held until it lands.
        .{ .input = testHistoryWanted(3, false), .commands = &.{} },

        // tmux has only two more. They go in above, and the ask that
        // was held goes out, measured from before they arrived.
        .{
            .input = .{ .tmux = .{ .block_end = "a\r\nb\r\nc" } },
            .commands = &.{"capture-pane -p -e -C -q -S -6 -E -3 -t %0\n"},
        },
    });
    try expectMirrorHistory(&mirror, "a\nb\nc\nd\ne");

    // Which reads what the display has by now, and adds nothing.
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .block_end = "a\r\nb\r\nc" } },
        .commands = &.{},
    }});
    try expectMirrorHistory(&mirror, "a\nb\nc\nd\ne");

    // From the top of what it has, tmux has nothing older: asked to end
    // past its history, it answers with its oldest line alone, and the
    // display is not sent anything.
    const ops = mirror.ops;
    try testViewer(&viewer, &.{
        .{
            .input = testHistoryWanted(5, false),
            .commands = &.{"capture-pane -p -e -C -q -S -8 -E -5 -t %0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "a" } }, .commands = &.{} },
    });
    try testing.expectEqual(ops, mirror.ops);
    try testing.expect(!viewer.panes.get(0).?.older_reading);
    try testing.expect(viewer.command_queue.empty());
}

test "older history is not read while a read from scratch is on its way" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    // The pane's first read is queued and unanswered.
    try testViewer(&viewer, testSinglePaneSteps()[0..4]);
    try testViewer(&viewer, &.{
        .{ .input = testHistoryWanted(3, false), .commands = &.{} },

        // Nor once its history is in and its screens are not.
        .{ .input = .{ .tmux = .{ .block_end = "c\r\nd\r\ne" } } },
        .{ .input = testHistoryWanted(3, false), .commands = &.{} },
    });
    try testing.expect(!viewer.panes.get(0).?.older_reading);
}

test "older history stops at the history limit" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
        .history_limit = 5,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Up to the limit and no further.
        .{
            .input = testHistoryWanted(3, false),
            .commands = &.{"capture-pane -p -e -C -q -S -5 -E -3 -t %0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "a" } } },

        // All of it is still only as far as the limit.
        .{
            .input = testHistoryWanted(1, true),
            .commands = &.{"capture-pane -p -e -C -q -S -5 -E -1 -t %0\n"},
        },
        .{ .input = .{ .tmux = .{ .block_end = "a" } } },

        // Nothing past it, and nothing without a line to start from.
        .{ .input = testHistoryWanted(5, false), .commands = &.{} },
        .{ .input = testHistoryWanted(0, false), .commands = &.{} },
    });
}

test "all of the older history reads to the top" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = testHistoryWanted(3, true),
            .commands = &.{"capture-pane -p -e -C -q -S - -E -3 -t %0\n"},
        },
    });
}

test "older history is never asked for when history is read whole" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = testHistoryWanted(3, false), .commands = &.{} },
    });
}

test "a pane tmux resizes is read again with its history when it is read in chunks" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // Our scrollback reflowed by our rules and tmux's by its own, so
        // older lines could no longer be placed above ours: the pane's
        // newest chunk is read again with its screens.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a1dd,60x20,0,0,0",
                .visible_layout = "a1dd,60x20,0,0,0",
                .raw_flags = "*",
            } } },
            .commands = &.{
                "capture-pane -p -e -C -q -S -3 -E -1 -t %0",
                "capture-pane -p -e -C -N -a -t %0",
                "capture-pane -p -e -C -N -q -t %0",
                "list-panes",
            },
        },
    });

    // Not a full read as far as the user is told: nothing is missing
    // for long enough to say so.
    const pane = viewer.panes.get(0).?;
    try testing.expectEqual(0, pane.full_reads);
    try testing.expectEqual(.live, pane.status);
}

/// A viewer reading history in chunks of three, with `mirror` attached
/// to its one pane and holding three lines of history, "c" to "e".
fn testChunkedSteady(viewer: *Viewer, mirror: *MirrorSink) !void {
    try testViewer(viewer, testSinglePaneSteps()[0..4]);
    try viewer.attachPane(0, mirror.sink());
    try testViewer(viewer, &(testPrimaryCaptureSteps("c\r\nd\r\ne", "x") ++
        testSubscribeSteps()));
    try testViewer(viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try expectMirrorHistory(mirror, "c\nd\ne");
}

test "a display needing all of its history has it read whole, and is told" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
        .history_limit = 1000,
    });
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.initScrollback(testing.allocator, testing.io, 83, 44, null);
    defer mirror.deinit();
    try testChunkedSteady(&viewer, &mirror);

    try testViewer(&viewer, &.{
        // As far back as the limit, not the chunk, with its screens.
        .{
            .input = .{ .read_history = .{ .pane_id = 0 } },
            .commands = &.{
                "capture-pane -p -e -C -q -S -1000 -E -1 -t %0\n",
                "capture-pane -p -e -C -N -a -t %0\n",
                "capture-pane -p -e -C -N -q -t %0\n",
                "list-panes",
            },
        },
        .{ .input = .{ .tmux = .{ .block_end = "a\r\nb\r\nc\r\nd\r\ne" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
    });

    // Not before the read is all in.
    try testing.expectEqual(0, mirror.completes);
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "x" } } }});
    try testing.expectEqual(1, mirror.completes);
    try expectMirrorHistory(&mirror, "a\nb\nc\nd\ne");

    // The pane state that follows tells it nothing more.
    try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try testing.expectEqual(1, mirror.completes);
    try testing.expect(viewer.command_queue.empty());
}

test "a display needing all of its history is told even when it is all read already" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.initScrollback(testing.allocator, testing.io, 83, 44, null);
    defer mirror.deinit();

    try testViewer(&viewer, testSinglePaneSteps());
    try viewer.attachPane(0, mirror.sink());
    try testViewer(&viewer, &([_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .read_history = .{ .pane_id = 0 } },
            .contains_command = "capture-pane -p -e -C -q -S - -E -1 -t %0\n",
        },
    } ++ testPrimaryCaptureSteps("all", "x")));
    try testing.expectEqual(1, mirror.completes);
}

test "history that drifted from tmux's is read again, once" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_chunk = 3,
    });
    defer viewer.deinit();

    var mirror: MirrorSink = undefined;
    try mirror.initScrollback(testing.allocator, testing.io, 83, 44, null);
    defer mirror.deinit();
    try testChunkedSteady(&viewer, &mirror);

    const reread_commands: []const []const u8 = &.{
        "capture-pane -p -e -C -q -S -3 -E -1 -t %0\n",
        "capture-pane -p -e -C -N -a -t %0\n",
        "capture-pane -p -e -C -N -q -t %0\n",
        "list-panes",
    };
    const older_command: []const []const u8 = &.{
        "capture-pane -p -e -C -q -S -6 -E -3 -t %0\n",
    };

    // tmux's line 3 back is not ours: the display refuses it, against
    // the one read from scratch it has had.
    try testViewer(&viewer, &.{
        .{ .input = testHistoryWanted(3, false), .commands = older_command },
        .{ .input = .{ .tmux = .{ .block_end = "a\r\nb\r\nq" } } },
    });
    try testing.expectEqual(1, mirror.drifted.?);
    try expectMirrorHistory(&mirror, "c\nd\ne");

    try testViewer(&viewer, &.{
        // Told so, the pane is read again from scratch, as for a resize.
        .{
            .input = .{ .history_drifted = .{ .pane_id = 0, .read = 1 } },
            .commands = reread_commands,
        },
        // Told again while that is on its way: nothing more.
        .{
            .input = .{ .history_drifted = .{ .pane_id = 0, .read = 1 } },
            .commands = &.{},
        },
        .{ .input = .{ .tmux = .{ .block_end = "p\r\nq\r\nr" } } },
        .{ .input = .{ .tmux = .{ .block_err = "no alternate screen" } } },
        .{ .input = .{ .tmux = .{ .block_end = "x" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },

        // A refusal measured against the history that read replaced
        // changes nothing.
        .{
            .input = .{ .history_drifted = .{ .pane_id = 0, .read = 1 } },
            .commands = &.{},
        },
    });
    try expectMirrorHistory(&mirror, "p\nq\nr");

    // Refused again, against the history the re-read left: reading
    // again would only go round, so older history stops.
    try testViewer(&viewer, &.{
        .{ .input = testHistoryWanted(3, false), .commands = older_command },
        .{ .input = .{ .tmux = .{ .block_end = "a\r\nb\r\nz" } } },
    });
    try testing.expectEqual(2, mirror.drifted.?);
    try testViewer(&viewer, &.{
        .{
            .input = .{ .history_drifted = .{ .pane_id = 0, .read = 2 } },
            .commands = &.{},
        },
        .{ .input = testHistoryWanted(3, false), .commands = &.{} },
    });
    try testing.expect(viewer.panes.get(0).?.older_off);

    // Until the pane is read from scratch for another reason.
    try testViewer(&viewer, &([_]TestStep{
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "a1dd,60x20,0,0,0",
                .visible_layout = "a1dd,60x20,0,0,0",
                .raw_flags = "*",
            } } },
            .commands = reread_commands,
        },
    } ++ testPrimaryCaptureSteps("p\r\nq\r\nr", "x") ++ [_]TestStep{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = testHistoryWanted(3, false), .commands = older_command },
    }));
    try testing.expect(!viewer.panes.get(0).?.older_off);
}

test "attach restores the saved layout at the size asked for" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{ .attach_layout = .restore });
    defer viewer.deinit();

    // Found even, saved at 3:1 at another size.
    try testViewer(&viewer, testTwoPaneSteps(two_panes_horizontal));
    try testViewer(&viewer, &.{
        // The pane state, then the saved layouts, asked for last.
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "@0 0ad6,81x24,0,0{60x24,0,0,0,20x24,61,0,1}" } },
            .commands = &.{},
        },

        // The panes report as the GUI laid them out from what it found.
        // The window is asked for, and laid out whole at that size:
        // 82 columns of panes in 3:1, the remainder to the smaller.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 41, .rows = 44 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 44 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "select-layout -t @0 '25fb,83x44,0,0{61x44,0,0,0,21x44,62,0,1}'\n",
            },
        },
    });

    // Once only: answered, the layout is the one to save from now on.
    for (0..2) |_| try testViewer(&viewer, &.{.{ .input = .{ .tmux = .{ .block_end = "" } } }});
    try testViewer(&viewer, &.{.{
        .input = .{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = "25fb,83x44,0,0{61x44,0,0,0,21x44,62,0,1}",
            .visible_layout = "25fb,83x44,0,0{61x44,0,0,0,21x44,62,0,1}",
            .raw_flags = "*",
        } } },
        .contains_command = "set-option -w -t @0 @ghostty-layout '25fb,83x44,0,0{61x44,0,0,0,21x44,62,0,1}'\n",
    }});
    try testing.expect(!viewer.windows.items[0].arrange_pending);
}

test "attach equalizes a window whose panes changed since it was saved" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{ .attach_layout = .restore });
    defer viewer.deinit();

    // Found side by side, unevenly; saved one above the other.
    try testViewer(&viewer, testTwoPaneSteps("085b,83x44,0,0{20x44,0,0,0,62x44,21,0,1}"));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "@0 " ++ two_panes_vertical } } },
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 20, .rows = 44 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 62, .rows = 44 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "select-layout -t @0 '1c1b,83x44,0,0{41x44,0,0,0,41x44,42,0,1}'\n",
            },
        },
    });
}

test "attach lays out a window sized before its saved layout arrived" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{ .attach_layout = .restore });
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps(two_panes_horizontal));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // The panes report over a slow link, ahead of the saved layout:
        // the window and its panes are sized as ever, and its layout
        // waits.
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 41, .rows = 44 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 41, .rows = 44 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %0 -x 41 -y 44\n",
                "resize-pane -t %1 -x 41 -y 44\n",
            },
        },
        .{
            .input = .{ .tmux = .{ .block_end = "@0 0ad6,81x24,0,0{60x24,0,0,0,20x24,61,0,1}" } },
            .commands = &.{
                "select-layout -t @0 '25fb,83x44,0,0{61x44,0,0,0,21x44,62,0,1}'\n",
            },
        },
    });
}

test "attach leaves the layout alone by default" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, testTwoPaneSteps("085b,83x44,0,0{20x44,0,0,0,62x44,21,0,1}"));
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .resize = .{ .pane_id = 0, .cols = 20, .rows = 44 } } },
        .{
            .input = .{ .resize = .{ .pane_id = 1, .cols = 62, .rows = 44 } },
            .commands = &.{
                "refresh-client -C @0:83x44\n",
                "resize-pane -t %0 -x 20 -y 44\n",
                "resize-pane -t %1 -x 62 -y 44\n",
            },
        },
    });
}
