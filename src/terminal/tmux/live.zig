//! Integration tests that drive a real tmux server.
//!
//! Everything else in this directory tests our side of the protocol against
//! transcripts we wrote ourselves, which can only ever prove that we parse
//! our own fiction. The bugs that have actually bitten here were all the
//! other kind: tmux doing something we did not know it did. Octal-escaped
//! `%output`, raw ESC inside a `%begin` block, a per-window size that only
//! exists from tmux 3.4 — none of those are discoverable without tmux in
//! the loop.
//!
//! So this spawns one. A private server on its own socket, with no user
//! config, attached over a pty by a control client, and the bytes it sends
//! run through the same `Parser` -> `dcs.Handler` -> `Viewer` chain a real
//! surface uses. Assertions read the pane terminals the viewer maintains,
//! and anything that needs an outside opinion asks the tmux CLI on the same
//! socket.
//!
//! ## Running these
//!
//! `zig build test-tmux-live`. They are skipped by `zig build test`: they
//! need a tmux binary and they take wall-clock time waiting on another
//! process, neither of which belongs in the default suite. The gate is the
//! `GHOSTTY_TMUX_LIVE` environment variable, set by that build step.
//!
//! ## What this does not cover
//!
//! The chain stops at the viewer. `Router`, `Termio`, and the apprts are
//! above it, so nothing here says anything about throughput: tmux kills a
//! control client that falls too far behind (`%exit too far behind`), and
//! this harness drains the pty as fast as it can, so it can never provoke
//! that. Testing it needs a harness built on `Termio` with a deliberately
//! slow endpoint.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const build_options = @import("terminal_options");

const Parser = @import("../Parser.zig");
const Screen = @import("../Screen.zig");
const dcs = @import("../dcs.zig");
const ptypkg = @import("../../pty.zig");
const osfile = @import("../../os/file.zig");
const global = @import("../../global.zig");
const Viewer = @import("viewer.zig").Viewer;
const sinkpkg = @import("sink.zig");
const Sink = sinkpkg.Sink;

const log = std.log.scoped(.tmux_live);

/// How long any single wait is allowed to take. Generous on purpose: a
/// timeout here should mean "this will never happen", not "the machine was
/// busy". A passing run does not spend it.
const timeout_ms: u64 = 10_000;

/// How long a single poll waits. Also the granularity of `waitFor`.
const poll_ms: u64 = 20;

/// Whether these tests should run at all.
///
/// They are opt-in rather than "run if tmux is installed", because a
/// developer having tmux on their PATH is not consent to spawn servers and
/// block on them during `zig build test`.
fn enabled() bool {
    if (comptime builtin.os.tag == .windows) return false;
    if (comptime !build_options.tmux_control_mode) return false;
    return global.environ().getPosix("GHOSTTY_TMUX_LIVE") != null;
}

/// A tmux server, a control client attached to it over a pty, and the
/// viewer being fed by that client.
const Session = struct {
    alloc: Allocator,
    io: std.Io,

    /// The server socket, in the system temp directory under a random
    /// name so concurrent tests cannot see each other's servers.
    socket: [:0]const u8,

    pty: ptypkg.Pty,
    pid: posix.pid_t,

    parser: Parser,
    dcs_handler: dcs.Handler,
    viewer: Viewer,

    /// Set when the viewer emits `.exit`, i.e. control mode ended. A test
    /// that did not ask for that has found a bug.
    exited: bool = false,

    /// Bytes read off the pty, for throughput assertions.
    bytes: usize = 0,

    /// Somewhere for short answers from `ask` to live so tests do not
    /// have to free every one of them.
    scratch: [1024]u8 = undefined,
    scratch_len: usize = 0,

    /// How many `%pause` notifications tmux has sent us. A test that
    /// means to provoke one should check that it did.
    pauses: usize = 0,

    /// The notices the viewer has reported, by kind.
    notices: [std.meta.fields(Viewer.Notice.Kind).len]struct {
        count: usize = 0,
        last: [256]u8 = undefined,
        last_len: usize = 0,
    } = @splat(.{}),

    /// Start a server running `command` in its one pane, then attach.
    ///
    /// The session is created detached first so that `command` has already
    /// painted the pane by the time the control client arrives. That is the
    /// ordering that matters: it is what makes the viewer issue
    /// `capture-pane` against content rather than against a blank screen.
    fn start(
        alloc: Allocator,
        io: std.Io,
        cols: u16,
        rows: u16,
        command: []const u8,
    ) !Session {
        return startWith(alloc, io, cols, rows, command, .{});
    }

    const StartOptions = struct {
        /// Lazy history by default, as the app attaches.
        viewer: Viewer.Options = .{ .lazy_history = true },

        /// The server's `history-limit`, if not tmux's default. It only
        /// applies to panes created after it is set, so it has to be set
        /// before the session exists rather than by `ask` afterwards.
        history_limit: ?u32 = null,

        /// Wait until the pane holds at least this many lines of history
        /// before attaching, so a test about the attach capture is not
        /// racing the command that fills it.
        min_history: usize = 0,

        /// A tmux.conf for the server, instead of none at all. Written
        /// next to the socket and removed with it.
        config: ?[]const u8 = null,

        /// Commands to run in further windows, created with `-d` before
        /// the control client attaches so the session's first window
        /// stays current. This is how a test puts a pane outside tmux's
        /// current window into the attach, rather than adding it after,
        /// where it would arrive through notifications instead.
        extra_windows: []const []const u8 = &.{},

        /// Before attaching, wait until `display-message -p -t target
        /// format` prints `expect`. For state a command takes a moment
        /// to reach, which the attach should see rather than race.
        ready: ?struct {
            target: []const u8,
            format: []const u8,
            expect: []const u8,
        } = null,

        /// Attach with `-r`, as a read-only client.
        read_only: bool = false,
    };

    fn startWith(
        alloc: Allocator,
        io: std.Io,
        cols: u16,
        rows: u16,
        command: []const u8,
        opts: StartOptions,
    ) !Session {
        const socket = socket: {
            const dir = try osfile.allocTmpDir(alloc, global.environ());
            defer osfile.freeTmpDir(alloc, dir);

            var name_buf: [osfile.random_basename_len]u8 = undefined;
            const name = try osfile.randomBasename(&name_buf);

            break :socket try std.fmt.allocPrintSentinel(
                alloc,
                "{s}/ghostty-tmux-live-{s}",
                .{ dir, name },
                0,
            );
        };
        errdefer alloc.free(socket);

        // -f /dev/null: no user config. Anything a developer has in
        // ~/.tmux.conf could change layouts, key handling or the status
        // line, and a test that depends on the machine it runs on is not
        // a test.
        {
            var x_buf: [8]u8 = undefined;
            var y_buf: [8]u8 = undefined;
            var h_buf: [16]u8 = undefined;
            const x = try std.fmt.bufPrint(&x_buf, "{d}", .{cols});
            const y = try std.fmt.bufPrint(&y_buf, "{d}", .{rows});

            const config_path = try std.fmt.allocPrint(alloc, "{s}.conf", .{socket});
            defer alloc.free(config_path);
            if (opts.config) |config| {
                // Through the shell rather than a file API, the same way
                // everything else here reaches the filesystem.
                const out = try run(alloc, &.{
                    "sh", "-c", "printf '%s\\n' \"$0\" > \"$1\"", config, config_path,
                });
                alloc.free(out);
            }

            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(alloc);
            try argv.appendSlice(alloc, &.{
                "tmux", "-f",   if (opts.config != null) config_path else "/dev/null",
                "-S",   socket,
            });

            // One invocation, so the option is set on the server that
            // then creates the session rather than on one that exits in
            // between for want of sessions.
            if (opts.history_limit) |limit| {
                const h = try std.fmt.bufPrint(&h_buf, "{d}", .{limit});
                try argv.appendSlice(alloc, &.{
                    "start-server",  ";",
                    "set",           "-g",
                    "history-limit", h,
                    ";",
                });
            }

            try argv.appendSlice(alloc, &.{
                "new-session", "-d", "-x", x, "-y", y, command,
            });
            const out = try run(alloc, argv.items);
            alloc.free(out);
        }

        for (opts.extra_windows) |window_command| {
            const out = try run(alloc, &.{
                "tmux",       "-f", "/dev/null",    "-S", socket,
                "new-window", "-d", window_command,
            });
            alloc.free(out);
        }

        if (opts.ready) |ready| {
            var rounds: usize = 0;
            while (true) : (rounds += 1) {
                if (rounds >= timeout_ms / poll_ms) {
                    return error.TimedOutWaitingForTmux;
                }

                const out = try run(alloc, &.{
                    "tmux",            "-f", "/dev/null", "-S",         socket,
                    "display-message", "-p", "-t",        ready.target, ready.format,
                });
                defer alloc.free(out);
                if (std.mem.eql(u8, std.mem.trim(u8, out, " \r\n"), ready.expect)) break;
                try std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
            }
        }

        if (opts.min_history > 0) {
            var rounds: usize = 0;
            while (true) : (rounds += 1) {
                if (rounds >= timeout_ms / poll_ms) {
                    return error.TimedOutWaitingForTmux;
                }

                const out = try run(alloc, &.{
                    "tmux",            "-f", "/dev/null",       "-S", socket,
                    "display-message", "-p", "#{history_size}",
                });
                defer alloc.free(out);
                const lines = std.fmt.parseInt(
                    usize,
                    std.mem.trim(u8, out, " \r\n"),
                    10,
                ) catch 0;
                if (lines >= opts.min_history) break;
                try std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
            }
        }

        // The status line steals a row from the client size and is one
        // more thing to differ between tmux builds. Off.
        {
            const out = try run(alloc, &.{
                "tmux", "-f", "/dev/null", "-S",  socket,
                "set",  "-g", "status",    "off",
            });
            alloc.free(out);
        }

        var pty = try ptypkg.Pty.open(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        });
        errdefer pty.deinit();

        // -CC, not -C: only the doubled form wraps the stream in the DCS
        // that this whole chain exists to parse.
        const pid = if (opts.read_only) try spawn(&pty, &.{
            "tmux", "-f",  "/dev/null", "-S",
            socket, "-CC", "attach",    "-r",
        }) else try spawn(&pty, &.{
            "tmux", "-f",  "/dev/null", "-S",
            socket, "-CC", "attach",
        });
        errdefer {
            posix.kill(pid, .KILL) catch {};
            reap(pid);
        }

        var viewer = try Viewer.init(io, alloc, opts.viewer);
        errdefer viewer.deinit();

        return .{
            .alloc = alloc,
            .io = io,
            .socket = socket,
            .pty = pty,
            .pid = pid,
            .parser = .init(),
            .dcs_handler = .{ .state = .{ .inactive = {} } },
            .viewer = viewer,
        };
    }

    fn deinit(self: *Session) void {
        self.viewer.deinit();
        self.dcs_handler.deinit();
        posix.kill(self.pid, .KILL) catch {};

        // Close our end of the pty before reaping. On macOS a process
        // exiting with unread output still queued on its terminal blocks
        // in exit until that output drains, and after a flood nothing
        // would ever read it again, so waiting first never returns.
        self.pty.deinit();
        reap(self.pid);

        // Take the server down with us. Otherwise it outlives the test and
        // holds the socket, and on a machine running the suite repeatedly
        // that is a slow leak of tmux processes.
        if (run(self.alloc, &.{
            "tmux", "-f", "/dev/null", "-S", self.socket, "kill-server",
        })) |out| self.alloc.free(out) else |_| {}

        // The config written by `StartOptions.config`, if there was one.
        if (std.fmt.allocPrint(self.alloc, "{s}.conf", .{self.socket})) |path| {
            defer self.alloc.free(path);
            if (run(self.alloc, &.{ "rm", "-f", path })) |out| self.alloc.free(out) else |_| {}
        } else |_| {}

        self.alloc.free(self.socket);
    }

    /// Read whatever the client has sent and feed it through the chain.
    /// Returns false if nothing arrived before the poll expired.
    ///
    /// Takes several buffers per call rather than one. A harness reading
    /// 4KB per round falls behind a pane writing at full speed, which
    /// shows up as an attach handshake timing out with its replies stuck
    /// behind megabytes of pane output.
    ///
    /// Bounded rather than "drain until empty": a pane running `yes` is
    /// never empty, so an unbounded drain never returns and the caller
    /// never gets to check its predicate.
    fn pump(self: *Session) !bool {
        var fds: [1]posix.pollfd = .{.{
            .fd = self.pty.master,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if (try posix.poll(&fds, poll_ms) == 0) return false;

        var any = false;
        var buf: [4096]u8 = undefined;
        for (0..64) |_| {
            const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
                // The client is gone; the pty gives EIO rather than EOF.
                error.InputOutput => return any,
                else => return err,
            };
            if (n == 0) return any;

            any = true;
            self.bytes += n;
            for (buf[0..n]) |byte| try self.feed(byte);

            // Anything more waiting right now? A zero timeout keeps this
            // from blocking once the burst is done.
            fds[0].revents = 0;
            if (try posix.poll(&fds, 0) == 0) return any;
        }
        return any;
    }

    fn feed(self: *Session, byte: u8) !void {
        for (self.parser.next(byte)) |maybe_action| {
            const action = maybe_action orelse continue;
            const cmd: ?dcs.Command = switch (action) {
                .dcs_hook => |hook| self.dcs_handler.hook(self.alloc, hook),
                .dcs_put => |b| self.dcs_handler.put(b),
                .dcs_unhook => self.dcs_handler.unhook(),

                // Anything outside the DCS is control mode having escaped
                // onto the host surface, which is the shape of the bug
                // that started all this. Say so loudly rather than
                // silently dropping it.
                else => {
                    if (self.dcs_handler.state == .inactive) continue;
                    log.warn("action outside the tmux DCS: {}", .{action});
                    continue;
                },
            };

            var command = cmd orelse continue;
            defer command.deinit();
            switch (command) {
                .tmux => |n| try self.notify(n),
                else => {},
            }
        }
    }

    fn notify(self: *Session, n: anytype) !void {
        // `.enter` is the DCS handler telling us control mode began; the
        // real stream handler creates the viewer on it. `.exit` is either
        // tmux's `%exit` or the DCS ending, and the stream handler feeds
        // it to the viewer before destroying it. Here the viewer outlives
        // the session struct, so entering is a no-op and exiting is
        // recorded and passed on.
        switch (n) {
            .pause => self.pauses += 1,
            .enter => return,
            // Still handed to the viewer, as the stream handler does, so
            // that tmux's reason for exiting is reported.
            .exit => self.exited = true,
            else => {},
        }

        try self.dispatch(self.viewer.next(.{ .tmux = n }));
    }

    /// Hand an input to the viewer, sending anything it asks for.
    fn input(self: *Session, in: Viewer.Input) !void {
        try self.dispatch(self.viewer.next(in));
    }

    fn dispatch(self: *Session, actions: []const Viewer.Action) !void {
        for (actions) |action| switch (action) {
            .command => |c| try self.write(c),
            .exit => self.exited = true,
            .notice => |n| {
                const kind = &self.notices[@intCast(@intFromEnum(n.kind))];
                kind.count += 1;
                const len = @min(n.text.len, kind.last.len);
                @memcpy(kind.last[0..len], n.text[0..len]);
                kind.last_len = len;
            },
            else => {},
        };
    }

    /// The last notice of a kind the viewer reported, or null if none.
    fn lastNotice(self: *const Session, kind: Viewer.Notice.Kind) ?[]const u8 {
        const k = &self.notices[@intCast(@intFromEnum(kind))];
        if (k.count == 0) return null;
        return k.last[0..k.last_len];
    }

    fn write(self: *Session, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rest = bytes[written..];
            const rc = posix.system.write(self.pty.master, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => written += @intCast(rc),
                .INTR, .AGAIN => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    /// Pump until `pred` is true, or fail.
    fn waitFor(
        self: *Session,
        comptime pred: fn (*Session) bool,
    ) !void {
        // `pump` blocks in poll for at most `poll_ms`, so counting rounds
        // is a clock: no timer needed, and a busy machine just spends
        // longer inside poll rather than spinning.
        var rounds: usize = 0;
        while (rounds < timeout_ms / poll_ms) : (rounds += 1) {
            _ = try self.pump();
            if (pred(self)) return;
        }
        return error.TimedOutWaitingForTmux;
    }

    /// The visible text of a pane's active screen, as the viewer has it.
    fn paneText(self: *Session, pane_id: usize) ![]const u8 {
        const entry = self.viewer.panes.getEntry(pane_id) orelse
            return error.NoSuchPane;
        const screen: *Screen = entry.value_ptr.*.terminal.screens.active;
        return screen.dumpStringAlloc(self.alloc, .{ .active = .{} });
    }

    /// Pump until a pane's visible text contains `needle`, or fail.
    fn waitForPaneText(
        self: *Session,
        pane_id: usize,
        needle: []const u8,
    ) !void {
        var rounds: usize = 0;
        while (rounds < timeout_ms / poll_ms) : (rounds += 1) {
            _ = try self.pump();
            const text = self.paneText(pane_id) catch continue;
            defer self.alloc.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
        }
        return error.TimedOutWaitingForTmux;
    }

    /// What tmux thinks one window's size is. Returned in a fixed buffer
    /// the session owns, so callers do not have to free it.
    fn windowSize(self: *Session, window_id: usize) ![]const u8 {
        const target = try std.fmt.allocPrint(self.alloc, "@{d}", .{window_id});
        defer self.alloc.free(target);

        const out = try self.ask(&.{
            "display-message",                  "-p", "-t", target,
            "#{window_width}x#{window_height}",
        });
        defer self.alloc.free(out);

        const trimmed = std.mem.trim(u8, out, " \r\n");
        @memcpy(self.scratch[0..trimmed.len], trimmed);
        return self.scratch[0..trimmed.len];
    }

    /// Ask tmux itself something, rather than trusting our own view of it.
    fn ask(self: *Session, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{
            "tmux", "-f", "/dev/null", "-S", self.socket,
        });
        try argv.appendSlice(self.alloc, args);
        return run(self.alloc, argv.items);
    }
};

/// Wait for a killed child so it does not linger as a zombie for the rest
/// of the test run.
fn reap(pid: posix.pid_t) void {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = posix.system.waitpid(pid, &status, 0);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => return,
        }
    }
}

/// Run a command to completion and return its stdout.
fn run(alloc: Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    );
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            log.warn(
                "tmux command failed code={d} stderr={s}",
                .{ code, result.stderr },
            );
            return error.TmuxCommandFailed;
        },
        else => return error.TmuxCommandFailed,
    }
    return result.stdout;
}

/// fork/exec `argv` with both ends of `pty` wired up as its terminal.
///
/// Only `execve` is available to us, which does not search PATH, so this
/// goes through `sh -c 'exec "$0" "$@"'`. Passing the real argv as `$0`
/// and `$@` rather than interpolating it into the script means the shell
/// never re-parses our arguments, so nothing here depends on what
/// characters a temp directory happens to contain.
fn spawn(pty: *ptypkg.Pty, argv: []const []const u8) !posix.pid_t {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix: []const []const u8 = &.{ "sh", "-c", "exec \"$0\" \"$@\"" };
    const argv_z = try alloc.allocSentinel(
        ?[*:0]const u8,
        prefix.len + argv.len,
        null,
    );
    for (prefix, 0..) |arg, i| argv_z[i] = try alloc.dupeZ(u8, arg);
    for (argv, 0..) |arg, i| argv_z[prefix.len + i] = try alloc.dupeZ(u8, arg);

    const rc = posix.system.fork();
    const pid: posix.pid_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        // Child. Nothing here may return: an error has to become an exit,
        // or we end up with two test runners.
        //
        // The slave has to be the child's std streams before
        // `childPreExec` runs, because that is what closes both ends. dup2
        // rather than dup3 so this stays the same on macOS; the fds we are
        // duplicating onto are not CLOEXEC.
        for ([_]posix.fd_t{ 0, 1, 2 }) |target| {
            if (posix.system.dup2(pty.slave, target) < 0) posix.system.exit(1);
        }
        pty.childPreExec() catch posix.system.exit(1);
        _ = std.c.execve(
            "/bin/sh",
            argv_z.ptr,
            @ptrCast(std.c.environ),
        );
        posix.system.exit(1);
    }
    return pid;
}

fn attached(self: *Session) bool {
    return self.viewer.panes.count() > 0 and
        self.viewer.command_queue.empty();
}

test "live: pane output arrives unescaped" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // `cat` rather than something that prints and exits, because this test
    // is about %output. Content already on screen when we attach comes
    // through `capture-pane` instead, which is a different path with a
    // different escaping dialect.
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();

    try session.waitFor(attached);

    // A full round trip: send-keys into the pane, the tty echoes it, cat
    // repeats it, and all of that comes back to us as %output.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "alpha\rbeta\r",
    } });
    try session.waitForPaneText(0, "beta");

    const text = try session.paneText(0);
    defer alloc.free(text);

    // tmux escapes every byte below a space in %output, so the carriage
    // returns arrive as the four characters `\015`. Undecoded they print
    // as text, nothing ever returns to column 0, and both words pile onto
    // one line -- which is exactly what the first real run of this looked
    // like.
    try testing.expect(std.mem.indexOf(u8, text, "\\015") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var alpha_on_its_own_line = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "alpha")) {
            alpha_on_its_own_line = true;
        }
    }
    try testing.expect(alpha_on_its_own_line);
    try testing.expect(!session.exited);
}

test "live: a styled pane survives its own capture" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // The content is already on screen when the control client attaches,
    // so the viewer's startup `capture-pane` has something styled to
    // replay. Without -C the reply carries raw ESC bytes, those end the
    // DCS carrying control mode, and the viewer goes defunct.
    var session = try Session.start(
        alloc,
        testing.io,
        80,
        24,
        "printf '\\033[31mRED\\033[0m plain\\r\\n'; sleep 60",
    );
    defer session.deinit();

    try session.waitFor(attached);

    const text = try session.paneText(0);
    defer alloc.free(text);

    try testing.expect(!session.exited);
    try testing.expect(std.mem.indexOf(u8, text, "RED plain") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    // The escape was obeyed, not just swallowed: the cell is red.
    const entry = session.viewer.panes.getEntry(0).?;
    const screen: *Screen = entry.value_ptr.*.terminal.screens.active;
    const cell = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const page = cell.node.page();
    const style = page.styles.get(page.memory, cell.cell.style_id);
    try testing.expectEqual(
        @as(u8, 1),
        style.fg_color.palette,
    );
}

test "live: a window follows the size we ask for" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // A second window, untouched, as the control: a client-wide resize
    // would take it along; a per-window one must leave it exactly as it
    // was.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const resized = session.viewer.windows.items[0].id;
    const untouched = session.viewer.windows.items[1].id;

    try session.input(.{ .resize = .{
        .pane_id = session.viewer.windows.items[0].layout.content.pane,
        .cols = 120,
        .rows = 40,
    } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // The window we asked about took the size.
    try testing.expectEqualStrings(
        "120x40",
        try session.windowSize(resized),
    );

    // Three ways this is the per-window form and not the client-wide one,
    // which `list-windows` alone cannot tell apart because both leave the
    // target window at 120x40:
    //
    //   - the other window did not move,
    //   - the client's own size is unchanged,
    //   - and the session's is too.
    try testing.expectEqualStrings(
        "80x24",
        try session.windowSize(untouched),
    );
    {
        const w = try session.ask(&.{
            "list-clients", "-F", "#{client_width}",
        });
        defer alloc.free(w);
        try testing.expectEqualStrings("80", std.mem.trim(u8, w, " \r\n"));
    }

    try testing.expect(!session.exited);
}

test "live: a split window takes the size both its panes ask for" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // tmux's own split rather than ours, so this stays a test about
    // sizing and nothing else.
    {
        const out = try session.ask(&.{ "split-window", "-h", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty() and
                v.viewer.windows.items[0].layout.content == .horizontal;
        }
    }.pred);

    const window_id = session.viewer.windows.items[0].id;
    const children = session.viewer.windows.items[0].layout.content.horizontal;
    const left = children[0].content.pane;
    const right = children[1].content.pane;

    // The panes report one at a time, the way a relayout makes them. The
    // first says nothing to tmux on its own: a window composed from it
    // and its sibling's old size is a size nobody asked for, and tmux
    // honouring it would move the divider under us.
    try session.input(.{ .resize = .{
        .pane_id = left,
        .cols = 50,
        .rows = 30,
    } });
    try testing.expect(session.viewer.command_queue.empty());

    // The pair completes, so the window goes out at the size they add up
    // to -- 50 + divider + 60 -- with a command for each pane behind it.
    try session.input(.{ .resize = .{
        .pane_id = right,
        .cols = 60,
        .rows = 30,
    } });
    try testing.expectEqual(3, session.viewer.command_queue.len());

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty() and
                v.viewer.windows.items[0].layout.width == 111;
        }
    }.pred);

    // tmux's own account of what it did with all three.
    try testing.expectEqualStrings(
        "111x30",
        try session.windowSize(window_id),
    );

    const settled = session.viewer.windows.items[0].layout.content.horizontal;
    try testing.expectEqual(50, settled[0].width);
    try testing.expectEqual(60, settled[1].width);

    try testing.expect(!session.exited);
}

test "live: a flooding pane does not break the session" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Attach to a quiet pane and start the flood afterwards. Starting it
    // first means the attach handshake -- nine round trips -- races the
    // firehose for the same pty, which is not what this test is for and
    // loses about one run in three.
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();

    try session.waitFor(attached);

    const pane: *Viewer.Pane = session.viewer.panes.getEntry(0).?.value_ptr.*;
    const pages_before = pane.terminal.screens.active.pages.totalPages();

    // Styled output, not plain. An escape sequence is the thing that can
    // straddle two %output notifications -- tmux splits wherever the pty
    // write landed -- so a payload with nothing to escape would say
    // nothing about reassembly.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "while :; do printf '\\033[31mflood0123456789\\033[0m\\n'; done\r",
    } });

    // Bounded by a byte target rather than a fixed number of rounds: a
    // loaded machine reads fewer bytes per round, and a test that
    // measures the machine instead of the code fails for no reason.
    const target: usize = 512 * 1024;
    const before = session.bytes;
    var rounds: usize = 0;
    while (rounds < 4000) : (rounds += 1) {
        _ = try session.pump();
        if (session.exited) break;
        if (session.bytes - before >= target) break;
    }

    // The flood was real...
    try testing.expect(session.bytes - before >= target);
    try testing.expect(!session.exited);
    try testing.expect(session.viewer.panes.contains(0));

    // ...and the viewer applied it, rather than the bytes merely
    // arriving. Counting pty bytes alone would pass with the whole
    // pane pipeline disconnected.
    try testing.expect(
        pane.terminal.screens.active.pages.totalPages() > pages_before,
    );

    // The pane is coherent rather than a pile of fragments.
    const text = try session.paneText(0);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "flood0123456789") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\033") == null);

    // And the escapes were obeyed rather than printed, across however
    // many notification boundaries they were split over.
    const screen: *Screen = pane.terminal.screens.active;
    const cell = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const page = cell.node.page();
    const style = page.styles.get(page.memory, cell.cell.style_id);
    try testing.expectEqual(@as(u8, 1), style.fg_color.palette);
}

test "live: killing a tmux window drops it here too" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.windows.items.len);

    // A second window, so there is something left to be attached to when
    // the first one dies.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const doomed = session.viewer.windows.items[1].id;
    {
        const target = try std.fmt.allocPrint(alloc, "@{d}", .{doomed});
        defer alloc.free(target);
        const out = try session.ask(&.{ "kill-window", "-t", target });
        alloc.free(out);
    }

    // tmux suppresses the dying window's %layout-change, so the close
    // notification is the only word we get; without it the window would
    // sit here forever as a native window nobody can type into.
    //
    // Killing a window in our own session sends the *unlinked* spelling,
    // `%unlinked-window-close`, because the callback runs after the
    // window has already left the session. This is the case that matters
    // and the one this test covers. Plain `%window-close` arrives when a
    // window is moved out rather than killed, and is handled the same.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 1 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    for (session.viewer.windows.items) |w| {
        try testing.expect(w.id != doomed);
    }
    try testing.expect(!session.exited);
}

test "live: a stray line does not end the session" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();

    try session.waitFor(attached);

    // Feed the malformed line straight into the chain rather than asking
    // tmux to produce one.
    //
    // The obvious provocation -- `rename-window $'a\nb'`, since tmux
    // accepts any valid UTF-8 as a name -- does not work: tmux 3.5a runs
    // names through `utf8_stravis(VIS_OCTAL|VIS_CSTYLE)` in
    // `window_set_name`, so the wire carries `%window-renamed @0 a\nb`
    // with a literal backslash and 'n' on one line. A test written that
    // way passes with the recovery removed, which is worse than no test.
    //
    // Whether any tmux can put a raw newline at the start of a line is
    // not something we can prove from here, so the recovery stays as
    // defence for input we did not anticipate -- and this checks that the
    // defence works on the real chain, parser and viewer included.
    for ("stray line with no percent\n") |byte| try session.feed(byte);

    try testing.expect(!session.exited);

    // Not merely un-exited: still working. A parser left in the broken
    // state drops everything after it, so this would never arrive.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "survived\r",
    } });
    try session.waitForPaneText(0, "survived");
    try testing.expect(!session.exited);
}

test "live: a paused pane is resumed and re-read" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();

    try session.waitFor(attached);

    // Put something on screen first. It has to still be there afterwards:
    // the recovery re-reads the pane, and a re-read that dropped the
    // scrollback would be its own bug.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "echo before-pause\r",
    } });
    try session.waitForPaneText(0, "before-pause");

    // And enough lines before it that some are in scrollback. The
    // re-read replays the pane's history, and it has to replace what
    // the shadow terminal already holds rather than land on top of it.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "seq -f 'hist-%g' 1 40\r",
    } });
    try session.waitForPaneText(0, "hist-40");

    // Pause the pane outright rather than provoking tmux's own
    // pause-after timer. Falling behind on purpose does reach the same
    // code, but whether tmux decides we are late enough is a race, and it
    // fired about half the time. `control_pause_pane` is the same
    // function the timer calls (cmd-refresh-client.c), so this exercises
    // the identical path with none of the timing.
    //
    // We never enable pause-after ourselves; this is here because any
    // other client can, and a paused pane is indistinguishable from a
    // frozen one.
    {
        const clients = try session.ask(&.{
            "list-clients", "-F", "#{client_name}",
        });
        defer alloc.free(clients);
        const name = std.mem.trim(u8, clients, " \r\n");

        const out = try session.ask(&.{
            "refresh-client", "-t", name, "-A", "%0:pause",
        });
        alloc.free(out);
    }

    // While the pane is paused, make it print something. tmux discards a
    // paused pane's output rather than buffering it, so this can only
    // ever reach us through a capture -- which makes it the thing that
    // tells a real recovery apart from a bare resume. Sent through the
    // tmux CLI rather than the viewer so it does not queue behind the
    // recovery commands.
    {
        const out = try session.ask(&.{
            "send-keys", "-t", "%0", "echo during-pause", "Enter",
        });
        alloc.free(out);
    }

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.pauses > 0;
        }
    }.pred);

    // Its display is told it is behind until the re-read lands.
    try testing.expectEqual(.catching_up, session.viewer.panes.get(0).?.status);

    // The recovery is a resume plus a full re-read of the pane, because
    // tmux discards a paused pane's output rather than buffering it. It
    // has landed once the queue drains.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expect(!session.exited);
    try testing.expect(session.viewer.panes.contains(0));
    try testing.expectEqual(.live, session.viewer.panes.get(0).?.status);

    // The re-read half of the recovery. What the pane printed while it
    // was paused never came to us as %output -- tmux threw it away -- so
    // it is on screen only if we read the pane again afterwards. A
    // recovery that merely resumed would leave a permanent hole here.
    try session.waitForPaneText(0, "during-pause");

    // And the re-read neither cost us what was already there, by now
    // in scrollback, nor duplicated it: every line `seq` printed is in
    // the pane's history or on screen exactly once, as it is in tmux.
    {
        const pane = session.viewer.panes.get(0) orelse
            return error.NoSuchPane;
        const text = try pane.terminal.screens.get(.primary).?.dumpStringAlloc(
            alloc,
            .{ .screen = .{} },
        );
        defer alloc.free(text);
        try testing.expect(
            std.mem.indexOf(u8, text, "before-pause") != null,
        );
        var counts: [40]usize = @splat(0);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const n_str = std.mem.trimEnd(u8, line, " ");
            if (!std.mem.startsWith(u8, n_str, "hist-")) continue;
            const n = std.fmt.parseInt(usize, n_str["hist-".len..], 10) catch
                continue;
            if (n >= 1 and n <= 40) counts[n - 1] += 1;
        }
        for (counts, 1..) |count, n| {
            if (count != 1) log.err(
                "hist-{d} appears {d} times in:\n{s}",
                .{ n, count, text },
            );
            try testing.expectEqual(1, count);
        }
    }

    // Output reaches us again, which it would not if the pane were still
    // paused: tmux would be dropping it server side.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "echo resumed-ok\r",
    } });
    try session.waitForPaneText(0, "resumed-ok");
    try testing.expect(!session.exited);
}

/// A session whose one pane copies its input, byte for byte, into a file
/// the test can read: a raw-mode `cat`, so the tty changes nothing.
/// With `bracketed`, the pane asks for bracketed paste first, and the
/// session attaches only once it has, so the request is something tmux
/// saw and we never did.
const PasteTarget = struct {
    session: Session,
    path: []u8,

    fn start(alloc: Allocator, bracketed: bool) !PasteTarget {
        const out = try run(alloc, &.{ "mktemp", "-t", "ghostty-tmux-paste" });
        defer alloc.free(out);
        const path = try alloc.dupe(u8, std.mem.trim(u8, out, " \r\n"));
        errdefer alloc.free(path);

        const command = try std.fmt.allocPrint(
            alloc,
            "{s}stty raw -echo; exec cat > '{s}'",
            .{ if (bracketed) "printf '\\033[?2004h'; " else "", path },
        );
        defer alloc.free(command);

        var session = try Session.startWith(alloc, testing.io, 80, 24, command, .{
            .ready = .{
                .target = ":0",
                .format = "#{pane_current_command}",
                .expect = "cat",
            },
        });
        errdefer session.deinit();
        try session.waitFor(attached);

        return .{ .session = session, .path = path };
    }

    fn deinit(self: *PasteTarget) void {
        const alloc = self.session.alloc;
        self.session.deinit();
        if (run(alloc, &.{ "rm", "-f", self.path })) |out| alloc.free(out) else |_| {}
        alloc.free(self.path);
    }

    /// Pump until the pane has received exactly `expected`, or fail
    /// with what it did receive.
    fn expectReceived(self: *PasteTarget, expected: []const u8) !void {
        const alloc = self.session.alloc;
        var rounds: usize = 0;
        while (rounds < timeout_ms / poll_ms) : (rounds += 1) {
            _ = try self.session.pump();
            const got = try run(alloc, &.{ "cat", self.path });
            defer alloc.free(got);
            if (got.len < expected.len) continue;
            if (!std.mem.eql(u8, got, expected)) {
                log.err("pane received {d} bytes: {f}", .{
                    got.len,
                    std.zig.fmtString(got[0..@min(got.len, 512)]),
                });
                return error.TestUnexpectedResult;
            }
            return;
        }
        return error.TimedOutWaitingForTmux;
    }
};

test "live: a paste into a program that asked for bracketed paste is bracketed" {
    if (!enabled()) return error.SkipZigTest;

    var target = try PasteTarget.start(testing.allocator, true);
    defer target.deinit();

    // The program asked before we attached, and tmux has no format for
    // it, so our terminal does not know. This is the case a paste
    // framed by our own idea of the mode gets wrong.
    {
        const pane = target.session.viewer.panes.get(0) orelse
            return error.NoSuchPane;
        try testing.expect(!pane.terminal.modes.get(.bracketed_paste));
    }

    try target.session.input(.{ .paste = .{
        .pane_id = 0,
        .data = "if x:\r    y\r",
    } });
    try target.expectReceived("\x1b[200~if x:\r    y\r\x1b[201~");
    try testing.expect(!target.session.exited);
}

test "live: a paste into a program that did not ask is not bracketed" {
    if (!enabled()) return error.SkipZigTest;

    var target = try PasteTarget.start(testing.allocator, false);
    defer target.deinit();

    // And it lands between the keys typed either side of it, in order:
    // the paste and the keys are separate commands in the same queue.
    try target.session.input(.{ .write = .{ .pane_id = 0, .data = "before " } });
    try target.session.input(.{ .paste = .{
        .pane_id = 0,
        .data = "-pasted \"$HOME\" #{pane_id} \\ \xc3\xa9\r",
    } });
    try target.session.input(.{ .write = .{ .pane_id = 0, .data = " after" } });
    try target.expectReceived(
        "before -pasted \"$HOME\" #{pane_id} \\ \xc3\xa9\r after",
    );
    try testing.expect(!target.session.exited);
}

test "live: a large paste through a paste buffer arrives whole and in order" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var target = try PasteTarget.start(alloc, false);
    defer target.deinit();

    // About 200KB of numbered lines, each with a two-byte character in
    // it, so that the chunks the paste is set in split some of them.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var i: usize = 0;
    while (data.items.len < 200 * 1024) : (i += 1) {
        try data.print(alloc, "line-{d:0>6} \xc3\xa9\r", .{i});
    }
    try testing.expect(data.items.len > 4 * Viewer.max_set_buffer_bytes);

    try target.session.input(.{ .paste = .{ .pane_id = 0, .data = data.items } });
    try target.expectReceived(data.items);
    try testing.expect(!target.session.exited);
}

test "live: window names arrive and follow renames" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // A name with spaces in it, because that is the case the format
    // cannot handle by splitting: `list-windows` separates its fields
    // with spaces, so the name has to be the rest of the line.
    {
        const out = try session.ask(&.{ "rename-window", "my long name" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len > 0 and
                std.mem.eql(u8, v.viewer.windows.items[0].name, "my long name");
        }
    }.pred);

    // And a name arriving through `list-windows` rather than through the
    // rename notification, which is the other half of the plumbing: a new
    // window forces a re-list.
    {
        const out = try session.ask(&.{
            "new-window", "-d", "-n", "second window", "sleep 60",
        });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            if (v.viewer.windows.items.len != 2) return false;
            if (!v.viewer.command_queue.empty()) return false;
            for (v.viewer.windows.items) |w| {
                if (std.mem.eql(u8, w.name, "second window")) return true;
            }
            return false;
        }
    }.pred);

    // The first window kept its name across the re-list.
    var found = false;
    for (session.viewer.windows.items) |w| {
        if (std.mem.eql(u8, w.name, "my long name")) found = true;
    }
    try testing.expect(found);
    try testing.expect(!session.exited);
}

test "live: a new tab is a new tmux window" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.windows.items.len);

    try session.input(.new_window);

    // tmux answers with %window-add, which re-lists, which is what makes
    // the window appear here. Nothing is remembered in between.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // And tmux agrees, rather than us having invented a window.
    const count = try session.ask(&.{
        "display-message", "-p", "#{session_windows}",
    });
    defer alloc.free(count);
    try testing.expectEqualStrings("2", std.mem.trim(u8, count, " \r\n"));
    try testing.expect(!session.exited);
}

test "live: a hostile window name does not become a command" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // A second window, whose only job is to still be here at the end.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const victim = session.viewer.windows.items[1].id;
    const pane = session.viewer.windows.items[0].layout.content.pane;

    // Everything that has to be neutralised, in one name: a newline that
    // would end the command and start another, a format job that would
    // run a shell, a command separator, and a quote that would end the
    // quoting. Fed unescaped this kills the other window.
    var buf: [128]u8 = undefined;
    const hostile = try std.fmt.bufPrint(
        &buf,
        "x\nkill-window -t @{d}\n#(touch /tmp/ghostty-pwned) ; it's",
        .{victim},
    );

    try session.input(.{ .rename_window = .{
        .pane_id = pane,
        .name = hostile,
    } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // The window it tried to kill is still here.
    {
        const count = try session.ask(&.{
            "display-message", "-p", "#{session_windows}",
        });
        defer alloc.free(count);
        try testing.expectEqualStrings("2", std.mem.trim(u8, count, " \r\n"));
    }

    // And the name is the literal text, with the control bytes gone and
    // the format job stored rather than run. tmux escapes what it stores,
    // so the `#` comes back as `#` and not as the output of anything.
    {
        const name = try session.ask(&.{
            "display-message", "-p", "-t", "@0", "#{window_name}",
        });
        defer alloc.free(name);
        const got = std.mem.trim(u8, name, " \r\n");
        try testing.expect(std.mem.indexOf(u8, got, "#(touch") != null);
        try testing.expect(std.mem.indexOf(u8, got, "it's") != null);
        try testing.expect(std.mem.indexOfScalar(u8, got, '\n') == null);
    }

    try testing.expect(!session.exited);
}

test "live: clearing a name gives the window back to tmux" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    const pane = session.viewer.windows.items[0].layout.content.pane;

    try session.input(.{ .rename_window = .{ .pane_id = pane, .name = "fixed" } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // Renaming turns automatic-rename off. That is tmux's doing, and it
    // is why clearing the name cannot just be an empty rename.
    {
        const opt = try session.ask(&.{
            "show-options", "-w", "-t", "@0", "-v", "automatic-rename",
        });
        defer alloc.free(opt);
        try testing.expectEqualStrings("off", std.mem.trim(u8, opt, " \r\n"));
    }

    try session.input(.{ .rename_window = .{ .pane_id = pane, .name = "" } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    {
        const opt = try session.ask(&.{
            "show-options", "-w", "-t", "@0", "-v", "automatic-rename",
        });
        defer alloc.free(opt);
        try testing.expectEqualStrings("on", std.mem.trim(u8, opt, " \r\n"));
    }

    try testing.expect(!session.exited);
}

test "live: moving a tab reorders tmux's windows" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    // Two more windows, so there is somewhere to move to.
    for (0..2) |_| {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 3 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const first = session.viewer.windows.items[0].id;
    const second = session.viewer.windows.items[1].id;

    // The pane in the first window, moved one to the right.
    const pane = session.viewer.windows.items[0].layout.content.pane;
    try session.input(.{ .move_window = .{ .pane_id = pane, .amount = 1 } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // tmux's order, asked of tmux. The two windows have exchanged
    // places and the third has not moved.
    const order = try session.ask(&.{
        "list-windows", "-F", "#{window_id}",
    });
    defer alloc.free(order);

    var it = std.mem.tokenizeScalar(u8, order, '\n');
    const line_one = std.mem.trim(u8, it.next() orelse return error.NoWindows, " \r");
    const line_two = std.mem.trim(u8, it.next() orelse return error.NoWindows, " \r");

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&buf, "@{d}", .{second}),
        line_one,
    );

    var buf2: [16]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&buf2, "@{d}", .{first}),
        line_two,
    );

    try testing.expect(!session.exited);
}

test "live: moving a tab two along shifts the one between, and we learn the order" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    for (0..2) |_| {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 3 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    var ids: [3]usize = undefined;
    for (session.viewer.windows.items, 0..) |w, i| ids[i] = w.id;

    const pane = session.viewer.windows.items[0].layout.content.pane;
    try session.input(.{ .move_window = .{ .pane_id = pane, .amount = 2 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // tmux says nothing when windows move, so this is the list we asked
    // for again: the first window last, the others each one back.
    const want = [_]usize{ ids[1], ids[2], ids[0] };
    for (session.viewer.windows.items, want) |w, id| {
        try testing.expectEqual(id, w.id);
    }

    // And it is tmux's order too.
    const order = try session.ask(&.{ "list-windows", "-F", "#{window_id}" });
    defer alloc.free(order);
    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    for (want) |id| try expected.writer.print("@{d}\n", .{id});
    try testing.expectEqualStrings(
        std.mem.trim(u8, expected.written(), "\n"),
        std.mem.trim(u8, order, " \r\n"),
    );
    try testing.expect(!session.exited);
}

test "live: zooming a pane round-trips through tmux" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try session.input(.{ .zoom_pane = .{ .pane_id = 1 } });

    // tmux answers with a layout, and that is what makes it true here.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items[0].zoomed_pane_id != null and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(1, session.viewer.windows.items[0].zoomed_pane_id.?);

    // tmux's own opinion, not ours.
    {
        const zoomed = try session.ask(&.{
            "display-message", "-p", "#{window_zoomed_flag}",
        });
        defer alloc.free(zoomed);
        try testing.expectEqualStrings("1", std.mem.trim(u8, zoomed, " \r\n"));
    }

    // Both panes are still here. A zoomed window's visible layout names
    // only the zoomed pane, and this is what would break if that ever
    // drove the pane diff.
    try testing.expectEqual(2, session.viewer.panes.count());

    // And it toggles back.
    try session.input(.{ .zoom_pane = .{ .pane_id = 1 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items[0].zoomed_pane_id == null and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(2, session.viewer.panes.count());
    try testing.expect(!session.exited);
}

test "live: tmux changing window tells us, and settles" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // We learned which window is current from `list-windows`, without
    // being told: %session-window-changed only fires on a change.
    try testing.expect(session.viewer.current_window_id != null);
    const first = session.viewer.windows.items[0].id;
    const second = session.viewer.windows.items[1].id;
    try testing.expectEqual(first, session.viewer.current_window_id.?);

    // Somebody else moves the session to the other window.
    {
        const target = try std.fmt.allocPrint(alloc, "@{d}", .{second});
        defer alloc.free(target);
        const out = try session.ask(&.{ "select-window", "-t", target });
        alloc.free(out);
    }

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.current_window_id != null and
                v.viewer.current_window_id.? != v.viewer.windows.items[0].id and
                v.viewer.command_queue.empty();
        }
    }.pred);

    try testing.expectEqual(second, session.viewer.current_window_id.?);
    for (session.viewer.windows.items) |w| {
        try testing.expectEqual(w.id == second, w.active);
    }

    // And it settled: the notification did not send a command back, so
    // there is nothing in flight and nothing more coming.
    try testing.expect(session.viewer.command_queue.empty());
    try testing.expect(!session.exited);
}

test "live: focusing a pane moves tmux's active pane" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // tmux makes the pane it just created the active one, so asking for
    // the *other* one is a real change and not a no-op that would pass
    // whatever we sent.
    const active_after_split = try session.ask(&.{
        "display-message", "-p", "#{pane_id}",
    });
    defer alloc.free(active_after_split);
    try testing.expectEqualStrings(
        "%1",
        std.mem.trim(u8, active_after_split, " \r\n"),
    );

    try session.input(.{ .select_pane = .{ .pane_id = 0 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    const active = try session.ask(&.{
        "display-message", "-p", "#{pane_id}",
    });
    defer alloc.free(active);
    try testing.expectEqualStrings("%0", std.mem.trim(u8, active, " \r\n"));
    try testing.expect(!session.exited);
}

test "live: tmux accepts the pause-after flag we send it" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "sleep 60",
        .{ .viewer = .{ .pause_after = 30 } },
    );
    defer session.deinit();

    try session.waitFor(attached);
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // The point of the test. `refresh-client -f` answers an unknown flag
    // with an error block, and an error block is not something the
    // startup sequence survives quietly -- so a session that is still
    // alive and idle here is tmux having accepted it.
    try testing.expect(!session.exited);

    // And tmux says so itself rather than us inferring it from silence.
    const flags = try session.ask(&.{
        "list-clients", "-F", "#{client_flags}",
    });
    defer alloc.free(flags);
    try testing.expect(
        std.mem.indexOf(u8, flags, "pause-after") != null,
    );
}

test "live: detaching ends control mode and leaves the session running" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expect(!session.exited);

    try session.input(.detach);

    // tmux ends control mode, which is how the GUI learns to close the
    // windows this client was showing.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.exited;
        }
    }.pred);

    // The half that makes this detach and not kill: the server is still
    // up and the session is still in it, with its window still running.
    // Without this the test passes just as well for `kill-session`.
    const sessions = try session.ask(&.{
        "list-sessions", "-F", "#{session_windows}",
    });
    defer alloc.free(sessions);
    try testing.expectEqualStrings("1", std.mem.trim(u8, sessions, " \r\n"));
}

test "live: a split makes a second pane in the same window" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expectEqual(1, session.viewer.panes.count());

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .right } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // Still one window: a split is a pane, not a tab.
    try testing.expectEqual(1, session.viewer.windows.items.len);

    // Side by side, as asked. tmux reports the layout, so this is its
    // opinion and not ours: two panes at the same y, different x.
    const layout = session.viewer.windows.items[0].layout;
    try testing.expect(layout.content == .horizontal);
    try testing.expect(!session.exited);
}

test "live: a pane in the alternate screen keeps both screens" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // tmux has no "alternate screen capture". A plain capture-pane reads
    // the grid on display, which here is the alternate screen, and `-a`
    // reads the primary grid tmux put aside when 1049 came on.
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "printf 'under'; printf '\\033[?1049hon-alt'; sleep 60",
        .{ .ready = .{
            .target = ":0",
            .format = "#{alternate_on}",
            .expect = "1",
        } },
    );
    defer session.deinit();

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return attached(v) and v.viewer.command_queue.empty();
        }
    }.pred);

    const pane = session.viewer.panes.get(0) orelse return error.NoSuchPane;
    try testing.expectEqual(.alternate, pane.terminal.screens.active_key);

    const text = try session.paneText(0);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "on-alt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "under") == null);

    const primary = try pane.terminal.screens.get(.primary).?.dumpStringAlloc(
        alloc,
        .{ .active = .{} },
    );
    defer alloc.free(primary);
    try testing.expect(std.mem.indexOf(u8, primary, "under") != null);
    try testing.expect(std.mem.indexOf(u8, primary, "on-alt") == null);
    try testing.expect(!session.exited);
}

test "live: a pane outside tmux's current window gets its state too" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // The second window is not current when we attach, and its program
    // has set modes and moved its cursor first. Only the pane-state
    // reply carries those, never a capture, and `list-panes` without
    // `-s` lists the current window alone.
    var session = try Session.startWith(alloc, testing.io, 80, 24, "sleep 60", .{
        .extra_windows = &.{
            "printf '\\033[?1h\\033[?1002h\\033[?1006h" ++
                "\\033[?1049hon-alt\\033[3;5H'; sleep 60",
        },
        .ready = .{
            .target = ":1",
            .format = "#{alternate_on},#{keypad_cursor_flag}," ++
                "#{mouse_button_flag},#{mouse_sgr_flag}," ++
                "#{cursor_x},#{cursor_y}",
            .expect = "1,1,1,1,4,2",
        },
    });
    defer session.deinit();

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return attached(v) and
                v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const pane = session.viewer.panes.get(1) orelse return error.NoSuchPane;
    const t = &pane.terminal;
    try testing.expectEqual(.alternate, t.screens.active_key);
    try testing.expect(t.modes.get(.cursor_keys));
    try testing.expect(t.modes.get(.mouse_event_button));
    try testing.expect(t.modes.get(.mouse_format_sgr));
    try testing.expectEqual(4, t.screens.active.cursor.x);
    try testing.expectEqual(2, t.screens.active.cursor.y);

    const text = try session.paneText(1);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "on-alt") != null);
    try testing.expect(!session.exited);
}

test "live: a downward split stacks the panes" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const layout = session.viewer.windows.items[0].layout;
    try testing.expect(layout.content == .vertical);
    try testing.expect(!session.exited);
}

test "live: a split to the left or up puts the new pane first" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try session.input(.{ .split = .{ .pane_id = 0, .direction = .left } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    {
        const layout = session.viewer.windows.items[0].layout;
        try testing.expect(layout.content == .horizontal);
        try testing.expectEqual(1, layout.content.horizontal[0].content.pane);
        try testing.expectEqual(0, layout.content.horizontal[1].content.pane);
    }

    try session.input(.{ .split = .{ .pane_id = 0, .direction = .up } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 3 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    {
        const layout = session.viewer.windows.items[0].layout;
        const right = layout.content.horizontal[1];
        try testing.expect(right.content == .vertical);
        try testing.expectEqual(2, right.content.vertical[0].content.pane);
        try testing.expectEqual(0, right.content.vertical[1].content.pane);
    }
    try testing.expect(!session.exited);
}

test "live: panes are swapped, moved, broken out and joined by tmux" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try session.input(.{ .split = .{ .pane_id = 0, .direction = .right } });
    const settled = struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred;
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    // Pane 0 trades places with the pane on its right, and stays the
    // active one, in its new place.
    try session.input(.{ .swap_pane = .{ .pane_id = 0, .target = .right } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const layout = v.viewer.windows.items[0].layout;
            return layout.content == .horizontal and
                layout.content.horizontal[1].content.pane == 0;
        }
    }.pred);
    try session.waitFor(settled);
    {
        const active = try session.ask(&.{ "display-message", "-p", "#{pane_id}" });
        defer alloc.free(active);
        try testing.expectEqualStrings("%0", std.mem.trim(u8, active, " \r\n"));
    }

    // Dropped below pane 0, pane 1 stacks under it.
    try session.input(.{ .move_pane = .{
        .pane_id = 1,
        .target_pane_id = 0,
        .direction = .down,
    } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const layout = v.viewer.windows.items[0].layout;
            return layout.content == .vertical and
                layout.content.vertical[1].content.pane == 1;
        }
    }.pred);

    // Broken out, pane 1 gets a window of its own.
    try session.input(.{ .break_pane = .{ .pane_id = 1 } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try testing.expectEqual(1, session.viewer.windows.items[1].layout.content.pane);

    // And joined back into the window before it, beside pane 0.
    try session.input(.{ .join_pane = .{ .pane_id = 1, .window = .previous } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 1 and
                v.viewer.panes.count() == 2 and
                v.viewer.windows.items[0].layout.content == .horizontal;
        }
    }.pred);
    try testing.expect(!session.exited);
}

test "live: a large styled history does not break the attach" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Fifty thousand coloured lines, which the attach captures with
    // `capture-pane -e -C -S -` as a single `%begin`/`%end` block of
    // several megabytes. A block cap sized for one line breaks the
    // parser part way through that reply, and from then on nothing from
    // tmux is ever read again: the session is frozen, not exited.
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "seq 50000 | awk '{ printf \"\\033[3%dm%06d coloured history\\033[0m\\n\", $1 % 8, $1 }'; exec cat",
        .{ .history_limit = 60000, .min_history = 49_000 },
    );
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expect(!session.exited);

    // Still talking to tmux, not merely un-exited.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "survived\r",
    } });
    try session.waitForPaneText(0, "survived");

    // And the captures that follow the big one were paired with the
    // right commands: the visible area is the visible area.
    const text = try session.paneText(0);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "050000 coloured history") != null);
    try testing.expect(!session.exited);
}

test "live: a big history attaches screen first and fills in after" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "seq 50000 | awk '{ printf \"\\033[3%dm%06d coloured history\\033[0m\\n\", $1 % 8, $1 }'; exec cat",
        .{ .history_limit = 60000, .min_history = 49_000 },
    );
    defer session.deinit();

    // The screen is there while the history is still on its way: the
    // history is megabytes, and arrives over many reads after it.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const pane = v.viewer.panes.get(0) orelse return false;
            if (pane.status != .loading_history) return false;
            const text = v.paneText(0) catch return false;
            defer v.alloc.free(text);
            return std.mem.indexOf(u8, text, "050000 coloured history") != null;
        }
    }.pred);

    // And then all of it is, exactly as an eager attach would have it.
    try session.waitFor(attached);
    const pane = session.viewer.panes.get(0).?;
    try testing.expectEqual(.live, pane.status);
    const text = try pane.terminal.screens.get(.primary).?.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(text);
    // The shadow terminal keeps only the newest of it, so this checks
    // the lines nearest the screen: there, and once each.
    try testing.expectEqual(1, std.mem.count(u8, text, "049990 coloured history"));
    try testing.expectEqual(1, std.mem.count(u8, text, "049999 coloured history"));
    try testing.expect(!session.exited);
}

test "live: tmux's messages for the user reach the viewer" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // A config with a mistake in it. tmux keeps the error for the first
    // client to attach, and writes it into that client's attach reply.
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "cat",
        .{ .config = "set -g status off\nthis-is-not-a-command" },
    );
    defer session.deinit();

    try session.waitFor(attached);
    {
        const err = session.lastNotice(.config_error) orelse
            return error.NoConfigError;
        try testing.expect(std.mem.indexOf(u8, err, "this-is-not-a-command") != null);
    }

    // `display-message` aimed at us, as a key binding or script in
    // another client would do.
    const client = try session.ask(&.{ "list-clients", "-F", "#{client_name}" });
    defer alloc.free(client);
    {
        const out = try session.ask(&.{
            "display-message",    "-c", std.mem.trim(u8, client, " \r\n"),
            "hello from display",
        });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.lastNotice(.message) != null;
        }
    }.pred);
    try testing.expectEqualStrings("hello from display", session.lastNotice(.message).?);

    // A command we send for the user that tmux refuses: a split of a
    // pane far too small to split again and again.
    for (0..40) |_| try session.input(.{ .split = .{ .pane_id = 0, .direction = .down } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.lastNotice(.command_error) != null and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try testing.expect(std.mem.indexOf(
        u8,
        session.lastNotice(.command_error).?,
        "no space",
    ) != null or std.mem.indexOf(
        u8,
        session.lastNotice(.command_error).?,
        "too small",
    ) != null);

    // Everything else tmux 3.6 tells a control client about, which must
    // all be taken in stride.
    const noise = [_][]const []const u8{
        &.{ "set-buffer", "-b", "buf1", "data" },
        &.{ "delete-buffer", "-b", "buf1" },
        &.{ "copy-mode", "-t", "%0" },
        &.{ "send-keys", "-t", "%0", "-X", "cancel" },
        &.{ "rename-session", "renamed session" },
        &.{ "new-session", "-d", "-s", "other", "cat" },
        &.{ "new-window", "-d", "-t", "other:", "cat" },
        &.{ "rename-window", "-t", "other:1", "otherwin" },
        &.{ "kill-window", "-t", "other:1" },
        &.{ "rename-window", "-t", "%0", "" },
        &.{ "kill-session", "-t", "other" },
    };
    for (noise) |args| {
        const out = try session.ask(args);
        alloc.free(out);
    }
    {
        const out = try session.ask(&.{
            "refresh-client", "-t",                              std.mem.trim(u8, client, " \r\n"),
            "-B",             "sub1:%0:#{pane_current_command}",
        });
        alloc.free(out);
    }

    // Still attached and still working. No newline: the splits above
    // left pane 0 a row or two high, and a line fed to `cat` would
    // scroll out of it again.
    try session.input(.{ .write = .{ .pane_id = 0, .data = "survived" } });
    try session.waitForPaneText(0, "survived");
    try testing.expect(!session.exited);
    try testing.expectEqual(.command_queue, session.viewer.state);

    // The window renamed to nothing came through as nothing, rather than
    // being dropped as malformed and keeping its old name. (Renaming
    // turns automatic-rename off, so tmux leaves it empty.)
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len > 0 and
                v.viewer.windows.items[0].name.len == 0;
        }
    }.pred);
}

test "live: tmux answers its panes' queries itself" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // The premise of a tmux pane surface not answering queries: tmux
    // already has. This harness never writes anything back on the pane's
    // behalf, so the reply the program reads can only be tmux's.
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();
    try session.waitFor(attached);

    // Ask for primary device attributes and show the first three bytes
    // of the reply, in hex so nothing in it is interpreted on the way
    // back.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "stty -echo -icanon; printf '\\033[c'; " ++
            "r=$(dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "echo reply:$r\r",
    } });
    try session.waitForPaneText(0, "reply:1b5b3f");

    // The query itself also reached us in %output, so a terminal
    // displaying the pane sees it too, and would answer it a second
    // time, as typed input, unless it knows not to. See
    // `StreamHandler.answer_queries`.
    try testing.expect(!session.exited);
}

test "live: a large paste arrives whole and in order" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();
    try session.waitFor(attached);

    // Non-canonical, so the tty's line length limit does not apply, and
    // no echo, so 200KB of it is not painted back at us. `cksum` reads
    // exactly the paste and says what it got.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "stty -icanon -echo; head -c 204800 | cksum\r",
    } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.command_queue.empty();
        }
    }.pred);

    // Bracketed, as a paste from the GUI would be, though `cksum` sees
    // the markers as data like everything else. Lines of a pattern that
    // shows reordering: each one numbered.
    var paste: std.ArrayList(u8) = .empty;
    defer paste.deinit(alloc);
    try paste.appendSlice(alloc, "\x1b[200~");
    var i: usize = 0;
    while (paste.items.len < 204800 - "\x1b[201~".len) : (i += 1) {
        try paste.print(alloc, "line {d:0>8} of the paste\n", .{i});
    }
    paste.shrinkRetainingCapacity(204800 - "\x1b[201~".len);
    try paste.appendSlice(alloc, "\x1b[201~");
    try testing.expectEqual(204800, paste.items.len);

    // What cksum should print for it, worked out by cksum itself.
    const expected = expected: {
        const out = try run(alloc, &.{
            "sh", "-c", "printf '%s' \"$0\" | cksum", paste.items,
        });
        defer alloc.free(out);
        break :expected try alloc.dupe(u8, std.mem.trim(u8, out, " \r\n"));
    };
    defer alloc.free(expected);

    try session.input(.{ .write = .{ .pane_id = 0, .data = paste.items } });

    // Give it the time a paste this size takes rather than the usual
    // wait: every byte is three on the wire.
    var rounds: usize = 0;
    while (rounds < 3 * timeout_ms / poll_ms) : (rounds += 1) {
        _ = try session.pump();
        const text = try session.paneText(0);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, expected) != null) break;
    } else return error.TimedOutWaitingForTmux;

    try testing.expect(!session.exited);
    try testing.expectEqual(.command_queue, session.viewer.state);
}

test "live: switching session mid-attach pairs every reply correctly" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // A second session with a different shape, so that reading one
    // session's replies as the other's would show.
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();
    {
        const out = try session.ask(&.{ "new-session", "-d", "-s", "other", "cat" });
        alloc.free(out);
    }
    {
        const out = try session.ask(&.{ "split-window", "-t", "other:", "cat" });
        alloc.free(out);
    }

    // Switch as soon as the first window list arrives, while that
    // window's captures are still on their way: their replies come after
    // the switch and must not be taken for the new session's.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() > 0;
        }
    }.pred);
    const client = try session.ask(&.{ "list-clients", "-F", "#{client_name}" });
    defer alloc.free(client);
    {
        const out = try session.ask(&.{
            "switch-client", "-c", std.mem.trim(u8, client, " \r\n"), "-t", "other",
        });
        alloc.free(out);
    }

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.count() == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try testing.expectEqual(1, session.viewer.windows.items.len);
    try testing.expect(!session.exited);

    // And it works: the new session's panes take input.
    var it = session.viewer.panes.iterator();
    const pane_id = it.next().?.key_ptr.*;
    try session.input(.{ .write = .{ .pane_id = pane_id, .data = "switched\r" } });
    try session.waitForPaneText(pane_id, "switched");
}

test "live: the GUI is told which pane and window tmux is on" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // A second window that becomes the current one, split so that its
    // active pane is not the first one listed.
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();
    try session.waitFor(attached);
    {
        const out = try session.ask(&.{ "new-window", "sleep 60" });
        alloc.free(out);
    }
    {
        const out = try session.ask(&.{ "split-window", "sleep 60" });
        alloc.free(out);
    }
    {
        const out = try session.ask(&.{ "select-pane", "-t", ":.0" });
        alloc.free(out);
    }
    {
        const out = try session.ask(&.{ "split-window", "-h", "sleep 60" });
        alloc.free(out);
    }

    // What tmux itself says, as the expectation.
    const want = try session.ask(&.{ "display-message", "-p", "#{window_id} #{pane_id}" });
    defer alloc.free(want);

    // The window list, re-read for the new window exactly as it is read
    // on attach, has to say where tmux is: not the first window, and not
    // the first pane listed in it.
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.panes.count() == 4 and
                v.viewer.command_queue.empty();
        }
    }.pred);

    const active: *const Viewer.Window = for (session.viewer.windows.items) |*w| {
        if (w.active) break w;
    } else return error.NoActiveWindow;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(
        std.mem.trim(u8, want, " \r\n"),
        try std.fmt.bufPrint(&buf, "@{d} %{d}", .{ active.id, active.active_pane_id.? }),
    );

    // And when tmux moves it, from another client here, the viewer
    // follows.
    const before = active.active_pane_id.?;
    {
        const out = try session.ask(&.{ "select-pane", "-t", ":.+" });
        alloc.free(out);
    }
    const now = try session.ask(&.{ "display-message", "-p", "#{pane_id}" });
    defer alloc.free(now);
    const now_id = try std.fmt.parseInt(usize, std.mem.trim(u8, now, "% \r\n"), 10);
    try testing.expect(now_id != before);

    const Ctx = struct {
        var want_window: usize = 0;
        var want_pane: usize = 0;
        fn pred(v: *Session) bool {
            for (v.viewer.windows.items) |w| {
                if (w.id == want_window) return w.active_pane_id == want_pane;
            }
            return false;
        }
    };
    Ctx.want_window = active.id;
    Ctx.want_pane = now_id;
    try session.waitFor(Ctx.pred);
    try testing.expect(!session.exited);
}

test "live: a read-only client keeps watching and keeps its hands off" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();
    try session.waitFor(attached);
    try testing.expect(!session.viewer.read_only);

    const raw = try session.ask(&.{ "list-clients", "-F", "#{client_name}" });
    defer alloc.free(raw);
    const client = std.mem.trim(u8, raw, " \r\n");

    // `switch-client -r` toggles the flag, and tmux announces it as a
    // change to the session we are already on.
    {
        const out = try session.ask(&.{ "switch-client", "-c", client, "-r" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.read_only and attached(v);
        }
    }.pred);
    try testing.expect(session.lastNotice(.message) != null);

    var it = session.viewer.panes.iterator();
    const pane_id = it.next().?.key_ptr.*;

    // tmux would run our send-keys regardless; it is refused here.
    try session.input(.{ .write = .{ .pane_id = pane_id, .data = "refused\r" } });
    try testing.expectEqualStrings("client is read-only", session.lastNotice(.command_error).?);
    try testing.expect(session.viewer.command_queue.empty());

    // Output still arrives while read-only.
    {
        const target = try std.fmt.allocPrint(alloc, "%{d}", .{pane_id});
        defer alloc.free(target);
        const out = try session.ask(&.{ "send-keys", "-t", target, "from elsewhere", "Enter" });
        alloc.free(out);
    }
    try session.waitForPaneText(pane_id, "from elsewhere");

    // And back.
    {
        const out = try session.ask(&.{ "switch-client", "-c", client, "-r" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return !v.viewer.read_only and attached(v);
        }
    }.pred);

    it = session.viewer.panes.iterator();
    const again = it.next().?.key_ptr.*;
    try session.input(.{ .write = .{ .pane_id = again, .data = "typed\r" } });
    try session.waitForPaneText(again, "typed");

    const text = try session.paneText(again);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "refused") == null);
    try testing.expect(!session.exited);
}

test "live: attaching read-only says so and still shows the pane" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(alloc, testing.io, 80, 24, "echo hello; cat", .{
        .read_only = true,
    });
    defer session.deinit();
    try session.waitFor(attached);
    try testing.expect(session.viewer.read_only);
    try testing.expect(session.lastNotice(.message) != null);

    var it = session.viewer.panes.iterator();
    const pane_id = it.next().?.key_ptr.*;
    try session.waitForPaneText(pane_id, "hello");
    try testing.expect(!session.exited);
}

test "live: characters are as wide here as tmux makes them" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "cat");
    defer session.deinit();
    try session.waitFor(attached);

    var it = session.viewer.panes.iterator();
    const pane_id = it.next().?.key_ptr.*;
    const target = try std.fmt.allocPrint(alloc, "%{d}", .{pane_id});
    defer alloc.free(target);

    // Typed into `cat`, so the tty's echo puts each on a line of its own.
    // Where the cursor ends up is how wide tmux made the line, and the
    // same has to hold for our copy of the pane: anything after a
    // character we disagree about is drawn in the wrong column.
    //
    // Left out, because we cannot match it: an emoji with a skin tone
    // modifier, which tmux 3.6 does not join and gives four columns.
    const cases = [_][]const u8{
        "a\u{65E5}\u{672C}\u{8A9E}b\u{1F389}ce\u{301}\u{301}d", // CJK, emoji, combining marks
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", // ZWJ sequence
        "\u{2764}\u{FE0F}", // made wide by VS16
        "\u{26A0}\u{FE0F}", // same
        "\u{1F1F8}\u{1F1EA}", // a flag
        "\u{263A}\u{FE0E}", // kept narrow by VS15
    };

    for (cases, 0..) |case, i| {
        var marker_buf: [8]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "#{d}#", .{i});
        const data = try std.mem.concat(alloc, u8, &.{ case, marker });
        defer alloc.free(data);

        try session.input(.{ .write = .{ .pane_id = pane_id, .data = data } });
        try session.waitForPaneText(pane_id, marker);

        // By the time the echo reached us tmux had put it in its grid.
        const out = try session.ask(&.{
            "display-message", "-p", "-t", target, "#{cursor_x}",
        });
        defer alloc.free(out);
        const want = try std.fmt.parseInt(usize, std.mem.trim(u8, out, " \r\n"), 10);

        const pane = session.viewer.panes.get(pane_id).?;
        const got = pane.terminal.screens.active.cursor.x;
        if (got != want) {
            log.err("{s}: tmux has the cursor at {d}, we have {d}", .{ case, want, got });
            return error.WidthMismatch;
        }

        try session.input(.{ .write = .{ .pane_id = pane_id, .data = "\r" } });
    }
    try testing.expect(!session.exited);
}

test "live: pane titles and working directories arrive by subscription" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    try testing.expect(session.viewer.server_host.len > 0);

    // Set by tmux itself, so nothing about it is in the pane's output:
    // only the subscription can tell us.
    {
        const out = try session.ask(&.{ "select-pane", "-t", "%0", "-T", "a live title" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const pane = v.viewer.panes.get(0) orelse return false;
            const title = pane.terminal.getTitle() orelse return false;
            return std.mem.eql(u8, title, "a live title");
        }
    }.pred);

    // tmux reads the working directory from the process, so `sleep`
    // has one without any shell integration.
    const want = try session.ask(&.{ "display-message", "-p", "-t", "%0", "#{pane_current_path}" });
    defer alloc.free(want);
    const path = std.mem.trim(u8, want, " \r\n");
    @memcpy(session.scratch[0..path.len], path);
    session.scratch_len = path.len;
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const pane = v.viewer.panes.get(0) orelse return false;
            const pwd = pane.terminal.getPwd() orelse return false;
            return std.mem.eql(u8, pwd, v.scratch[0..v.scratch_len]);
        }
    }.pred);
    try testing.expect(!session.exited);
}

test "live: a bell in another window flags it until tmux moves there" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();

    try session.waitFor(attached);
    {
        const out = try session.ask(&.{
            "new-window", "-d", "-n", "ringer", "sh -c 'sleep 0.3; printf \"\\a\"; sleep 60'",
        });
        alloc.free(out);
    }

    const ringing = struct {
        fn pred(v: *Session) bool {
            for (v.viewer.windows.items) |w| {
                if (std.mem.eql(u8, w.name, "ringer")) return w.alerts.bell;
            }
            return false;
        }
    }.pred;
    try session.waitFor(ringing);

    // Moving there, as selecting its tab would, clears it.
    {
        const out = try session.ask(&.{ "select-window", "-t", ":ringer" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            for (v.viewer.windows.items) |w| {
                if (std.mem.eql(u8, w.name, "ringer")) return w.active and !w.alerts.bell;
            }
            return false;
        }
    }.pred);
    try testing.expect(!session.exited);
}

test "live: a hidden pane's output goes off, and it catches up when shown" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "i=0; while :; do i=$((i+1)); echo tick-$i; sleep 0.05; done",
        .{ .viewer = .{ .hidden_output_off_after = 1 } },
    );
    defer session.deinit();

    try session.waitFor(attached);
    try session.input(.{ .pane_shown = .{ .pane_id = 0, .shown = false } });

    // As if it had been out of sight for a while; the next output turns
    // it off.
    const pane = session.viewer.panes.get(0).?;
    pane.hidden_since = pane.hidden_since.?.subDuration(.fromSeconds(2));
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.panes.get(0).?.output_off and v.viewer.command_queue.empty();
        }
    }.pred);

    // Nothing more arrives while it is off, so the pane falls behind.
    const before = try session.paneText(0);
    defer alloc.free(before);
    var rounds: usize = 0;
    while (rounds < 25) : (rounds += 1) _ = try session.pump();
    const during = try session.paneText(0);
    defer alloc.free(during);
    try testing.expectEqualStrings(before, during);

    // Shown again, it is read again and is current.
    try session.input(.{ .pane_shown = .{ .pane_id = 0, .shown = true } });
    try session.waitFor(attached);
    const now = try session.ask(&.{ "capture-pane", "-p", "-t", "%0" });
    defer alloc.free(now);
    const last = lastTick(now) orelse return error.NoTicks;
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const text = v.paneText(0) catch return false;
            defer v.alloc.free(text);
            return lastTick(text) != null;
        }
    }.pred);
    const shown = try session.paneText(0);
    defer alloc.free(shown);
    try testing.expect(lastTick(shown).? + 20 >= last);
    try testing.expect(!session.exited);
}

/// The number of the last `tick-N` line in `text`.
fn lastTick(text: []const u8) ?usize {
    var result: ?usize = null;
    var it = std.mem.tokenizeAny(u8, text, " \r\n");
    while (it.next()) |word| {
        if (!std.mem.startsWith(u8, word, "tick-")) continue;
        result = std.fmt.parseInt(usize, word["tick-".len..], 10) catch continue;
    }
    return result;
}

test "live: a typed command line's output and errors come back" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.start(alloc, testing.io, 80, 24, "sleep 60");
    defer session.deinit();
    try session.waitFor(attached);

    // Two commands on one line, so two replies before the marker's.
    try session.input(.{ .command_line = .{
        .text = "display-message -p hello ; display-message -p world",
    } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.lastNotice(.command_output) != null and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try testing.expectEqualStrings("hello\nworld", session.lastNotice(.command_output).?);

    try session.input(.{ .command_line = .{ .text = "switch-client -t no-such-session" } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.lastNotice(.command_error) != null and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try testing.expect(std.mem.indexOf(
        u8,
        session.lastNotice(.command_error).?,
        "no-such-session",
    ) != null);

    // Switching session from the prompt changes the session under the
    // line's own replies, and every reply still pairs up.
    {
        const out = try session.ask(&.{ "new-session", "-d", "-s", "typed", "sleep 60" });
        alloc.free(out);
    }
    try session.input(.{ .command_line = .{ .text = "switch-client -t typed" } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return std.mem.eql(u8, v.viewer.session_name, "typed") and
                v.viewer.panes.count() == 1 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    try session.input(.{ .command_line = .{ .text = "display-message -p after" } });
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            const last = v.lastNotice(.command_output) orelse return false;
            return std.mem.eql(u8, last, "after");
        }
    }.pred);
    try testing.expect(!session.exited);
}

test "live: windows moved by someone else are listed again in their new order" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(alloc, testing.io, 80, 24, "sleep 60", .{
        .viewer = .{ .follow_window_order = true },
    });
    defer session.deinit();
    try session.waitFor(attached);

    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.command_queue.empty();
        }
    }.pred);
    const first = session.viewer.windows.items[0].id;

    // Another client swapping them, which tmux tells us nothing about.
    {
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        const out = try session.ask(&.{
            "swap-window", "-d",
            "-s",          try std.fmt.bufPrint(&a, "@{d}", .{first}),
            "-t",          try std.fmt.bufPrint(&b, "@{d}", .{session.viewer.windows.items[1].id}),
        });
        alloc.free(out);
    }

    // tmux checks subscriptions about once a second.
    const Pred = struct {
        var id: usize = 0;
        fn pred(v: *Session) bool {
            return v.viewer.windows.items.len == 2 and
                v.viewer.windows.items[1].id == id;
        }
    };
    Pred.id = first;
    try session.waitFor(Pred.pred);
    try testing.expect(!session.exited);
}

test "live: tmux's status line is mirrored when asked for" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;
    var session = try Session.startWith(alloc, testing.io, 80, 24, "sleep 60", .{
        .viewer = .{ .status_line = true },
        .config = "set -g status-left '#[fg=red][left]#[default] '\nset -g status-right 'right #{session_windows}'",
    });
    defer session.deinit();
    try session.waitFor(attached);

    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return std.mem.eql(u8, v.viewer.status.left, "[left] ") and
                std.mem.eql(u8, v.viewer.status.right, "right 1") and
                v.viewer.status.windows.len > 0;
        }
    }.pred);

    // And followed when it changes.
    {
        const out = try session.ask(&.{ "new-window", "-d", "sleep 60" });
        alloc.free(out);
    }
    try session.waitFor(struct {
        fn pred(v: *Session) bool {
            return std.mem.eql(u8, v.viewer.status.right, "right 2");
        }
    }.pred);
    try testing.expect(!session.exited);
}

/// A sink that keeps what a display would be handed as passthrough, which
/// the viewer's own terminal skips.
const PassthroughSink = struct {
    alloc: Allocator,
    passthrough: std.ArrayList(u8) = .empty,

    fn deinit(self: *PassthroughSink) void {
        self.passthrough.deinit(self.alloc);
    }

    fn sink(self: *PassthroughSink) Sink {
        return .{ .ctx = self, .vtable = &.{
            .ops = ops,
            .close = close,
        } };
    }

    fn ops(ctx: *anyopaque, list: []const sinkpkg.Op) void {
        const self: *PassthroughSink = @ptrCast(@alignCast(ctx));
        for (list) |op| switch (op) {
            .passthrough => |b| self.passthrough.appendSlice(
                self.alloc,
                b,
            ) catch @panic("OOM"),
            else => {},
        };
    }

    fn close(_: *anyopaque) void {}
};

test "live: a notification wrapped for tmux's passthrough reaches the display" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    var session = try Session.start(alloc, testing.io, 80, 24, "sh");
    defer session.deinit();
    try session.waitFor(attached);

    var recorder: PassthroughSink = .{ .alloc = alloc };
    defer recorder.deinit();
    try session.viewer.attachPane(0, recorder.sink());

    // As Claude Code writes them with $TMUX set, and with
    // `allow-passthrough` at its default, off: tmux sends a control
    // client the pane's raw output either way. The text and cursor
    // movement in the second wrapper are not for us. The text is spelled
    // through a variable so that the echoed command line does not show
    // it either.
    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "j=junk; printf '\\033Ptmux;\\033\\033]777;notify;Claude Code;done\\033\\033\\\\\\033\\\\" ++
            "\\033Ptmux;'\"$j\"'-text\\033\\033[H\\033\\033]9;nine\\007\\033\\\\'; echo; echo END\r",
    } });
    try session.waitForPaneText(0, "\nEND");

    var rounds: usize = 0;
    while (rounds < timeout_ms / poll_ms and
        std.mem.indexOf(u8, recorder.passthrough.items, "nine") == null) : (rounds += 1)
    {
        _ = try session.pump();
    }
    try testing.expectEqualStrings(
        "\x1b]777;notify;Claude Code;done\x1b\\\x1b]9;nine\x07",
        recorder.passthrough.items,
    );

    const text = try session.paneText(0);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "junk-text") == null);
    try testing.expect(!session.exited);
}

test "live: OSC 8 hyperlinks survive the attach capture and live output" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // tmux keeps a pane's hyperlinks in its grid whatever the clients'
    // `hyperlinks` terminal feature says (that only decides whether tmux
    // draws them on a tty client), `capture-pane -e` writes them back
    // out as OSC 8, and live output carries the program's own OSC 8 raw.
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "printf '\\033]8;;https://example.com/old\\033\\\\OLD\\033]8;;\\033\\\\\\r\\n'; exec sh",
        // The link has been printed once the cursor is on the next line.
        .{ .ready = .{
            .target = ":0",
            .format = "#{cursor_y}",
            .expect = "1",
        } },
    );
    defer session.deinit();
    try session.waitFor(attached);

    // Captured on attach.
    try testing.expect(paneHasLink(&session, "https://example.com/old"));

    try session.input(.{ .write = .{
        .pane_id = 0,
        .data = "printf '\\033]8;;https://example.com/new\\033\\\\NEW\\033]8;;\\033\\\\\\n'\r",
    } });
    try session.waitForPaneText(0, "\nNEW");
    try testing.expect(paneHasLink(&session, "https://example.com/new"));
    try testing.expect(!session.exited);
}

/// Whether a row of pane 0 starts with a hyperlink to `uri`.
fn paneHasLink(session: *Session, uri: []const u8) bool {
    const pane = session.viewer.panes.get(0).?;
    const screen: *Screen = pane.terminal.screens.active;
    var it = screen.pages.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |row| {
        const cell = &row.cells(.all)[0];
        if (!cell.hyperlink) continue;
        const page = row.node.page();
        const id = page.lookupHyperlink(cell) orelse continue;
        const link = page.hyperlink_set.get(page.memory, id);
        if (std.mem.eql(u8, link.uri.slice(page.memory), uri)) return true;
    }
    return false;
}

test "live: a pane's modifyOtherKeys is restored on attach" {
    if (!enabled()) return error.SkipZigTest;

    const alloc = testing.allocator;

    // tmux only records the request with `extended-keys` on.
    var session = try Session.startWith(
        alloc,
        testing.io,
        80,
        24,
        "printf '\\033[>4;2m'; sleep 60",
        .{
            .config = "set -s extended-keys on",
            .ready = .{
                .target = ":0",
                .format = "#{pane_key_mode}",
                .expect = "Ext 2",
            },
        },
    );
    defer session.deinit();
    try session.waitFor(attached);

    const pane = session.viewer.panes.get(0).?;
    try testing.expect(pane.terminal.flags.modify_other_keys_2);
    try testing.expect(!session.exited);
}
