//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const oni = @import("oniguruma");

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of a single line: a notification, or one
    /// line of a `%begin` block. A line longer than this puts the parser
    /// into the broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    ///
    /// This is the limit that matters against hostile input. Anything
    /// can print `ESC P 1000 p` and start "control mode", and a line
    /// that never ends would otherwise grow the buffer until we run out
    /// of memory. Nothing tmux sends legitimately comes close: `%output`
    /// is chunked by the pty reads it came from, and the longest block
    /// lines are captured rows, tens of bytes per cell at the very worst.
    max_line_bytes: usize = 1024 * 1024,

    /// The maximum size in bytes of a `%begin` block's payload.
    ///
    /// Unlike a line, a block can legitimately be very large: the
    /// attach captures a pane's whole history with `capture-pane -e -S
    /// -`, and a large `history-limit` full of styled output is many
    /// megabytes. So exceeding this does not break the session. The
    /// oldest lines of the payload are dropped instead, keeping the
    /// newest (which, for a history capture, are the ones closest to
    /// the screen), and the block still ends normally so the reply stays
    /// paired with the command that asked for it. See `trimBlock`.
    max_block_bytes: usize = 64 * 1024 * 1024,

    /// Where the line currently being accumulated starts in the buffer.
    /// Only meaningful in the `.notification` and `.block` states.
    line_start: usize = 0,

    /// Whether the current block has had lines dropped by `trimBlock`.
    block_trimmed: bool = false,

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,

        /// Discarding a line that could not have been a notification.
        /// See the `.idle` arm of `put` for how we get here.
        skip_line,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    // Handle a byte of input.
    //
    // If we reach our byte limit this will return OutOfMemory. It only
    // does this on the first time we exceed the limit; subsequent calls
    // will return null as we drop all input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Every line tmux sends should begin with '%'. One that does
            // not is the tail of the line before it: tmux does not escape
            // names or command output, and both can contain a newline, so
            // `rename-window $'a\nb'` is enough to produce one. Ending
            // the session over that is a very large consequence for a very
            // small provocation, so drop the line instead.
            .idle => if (byte == '%') {
                self.buffer.clearRetainingCapacity();
                self.line_start = 0;
                self.state = .notification;
            } else if (byte != '\n') {
                self.buffer.clearRetainingCapacity();
                self.line_start = 0;
                self.state = .skip_line;
            },

            // Discarding a line we could not have understood.
            .skip_line => if (byte == '\n') {
                log.warn("discarded a stray control mode line", .{});
                self.state = .idle;
            },

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification() catch {
                    // If parsing failed, then we do not mark the state
                    // as broken because we may be able to continue parsing
                    // other types of notifications.
                    //
                    // In the future we may want to emit a notification
                    // here about unknown or unsupported notifications.
                    return null;
                };
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = self.line_start;
                const line = written[idx..];

                if (parseBlockTerminator(line)) |terminator| {
                    const output = std.mem.trimEnd(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );

                    if (self.block_trimmed) log.warn(
                        "tmux control mode block exceeded {} bytes, kept the newest {} bytes",
                        .{ self.max_block_bytes, output.len },
                    );

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    switch (terminator) {
                        .end => return .{ .block_end = output },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = output };
                        },
                    }
                }

                // Didn't end the block, continue accumulating. The newline
                // is stored below, so the next line starts after it.
                if (written.len + 1 > self.max_block_bytes) self.trimBlock();
                self.line_start = self.buffer.written().len + 1;
            },
        }

        // Only enforce the limit on the bytes of a line, not on the
        // newline ending it, so a line filling the limit exactly can still
        // be terminated. A newline stored in a block is already counted
        // as the start of the next line (`line_start` is past it).
        if (byte != '\n' and
            self.buffer.written().len - self.line_start >= self.max_line_bytes)
        {
            self.broken();
            return error.OutOfMemory;
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    /// Drop the oldest whole lines of the block being accumulated so that
    /// it fits in `max_block_bytes` with room to spare.
    ///
    /// Called just before the newline ending a block line is stored, so
    /// the buffer is whole lines (the last one less that newline) and the
    /// cut can land on a line boundary. `line_start` is still the start of
    /// that last line; the caller moves it on afterwards.
    ///
    /// Trims to half the cap rather than to just under it. Each trim moves
    /// what it keeps to the front of the buffer, and trimming a line at a
    /// time would move the whole block again for every line that arrives;
    /// trimming by half means each byte is moved a bounded number of times.
    fn trimBlock(self: *Parser) void {
        assert(self.state == .block);

        const written = self.buffer.written();
        const keep = self.max_block_bytes / 2;
        if (written.len <= keep) return;

        // The first line boundary leaving at most `keep` bytes behind it.
        // There may be none if the line just completed is longer than
        // that on its own, in which case keep exactly that line: it is
        // bounded by `max_line_bytes`, not by us.
        const cut: usize = if (std.mem.indexOfScalarPos(
            u8,
            written,
            written.len - keep,
            '\n',
        )) |nl| nl + 1 else self.line_start;
        if (cut == 0) return;

        const kept = written.len - cut;
        @memmove(written[0..kept], written[cut..]);
        self.buffer.shrinkRetainingCapacity(kept);
        self.block_trimmed = true;
    }

    const ParseError = error{RegexError};

    const BlockTerminator = enum { end, err };

    /// Block payload is raw data, so a line only terminates a block if it
    /// exactly matches tmux's `%end`/`%error` guard-line shape.
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;

        const time = fields.next() orelse return null;
        const command_id = fields.next() orelse return null;
        const flags = fields.next() orelse return null;
        const extra = fields.next();

        // In the future, we should compare these to the %begin block
        // because the tmux source guarantees that these always match and
        // that is a more robust way to match.
        _ = std.fmt.parseInt(usize, time, 10) catch return null;
        _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
        _ = std.fmt.parseInt(usize, flags, 10) catch return null;
        if (extra != null) return null;

        return terminator;
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // We don't use the rest of the tokens for now because tmux
            // claims to guarantee that begin/end are always in order and
            // never intermixed. In the future, we should probably validate
            // this.
            // TODO(tmuxcc): do this before merge?

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            self.line_start = 0;
            self.block_trimmed = false;
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            var re = oni.Regex.init(
                "^%output %([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const data = data: {
                const raw = line[@intCast(starts[2])..@intCast(ends[2])];
                break :data unescape(raw, raw);
            };

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-changed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            var re = oni.Regex.init(
                "^%layout-change @([0-9]+) (.+) (.+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const layout = line[@intCast(starts[2])..@intCast(ends[2])];
            const visible_layout = line[@intCast(starts[3])..@intCast(ends[3])];
            const raw_flags = line[@intCast(starts[4])..@intCast(ends[4])];

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%pause") or
            std.mem.eql(u8, cmd, "%continue"))
        cmd: {
            var re = oni.Regex.init(
                "^%(pause|continue) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const paused = line[@intCast(starts[1])] == 'p';
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return if (paused)
                .{ .pause = .{ .pane_id = id } }
            else
                .{ .@"continue" = .{ .pane_id = id } };
        } else if (std.mem.eql(u8, cmd, "%extended-output")) cmd: {
            var re = oni.Regex.init(
                // tmux(1) reserves room for arguments after the age
                // ("pane-id age ... : value") and says to ignore them.
                // They come before the first " : ", and the value is
                // everything after it.
                "^%extended-output %([0-9]+) ([0-9]+)(?: [^:]*)? : (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const age = std.fmt.parseInt(
                u64,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const data = data: {
                const raw = line[@intCast(starts[3])..@intCast(ends[3])];
                break :data unescape(raw, raw);
            };

            // Important: do not clear buffer here since data points to it
            self.state = .idle;
            return .{ .output = .{
                .pane_id = id,
                .data = data,
                .age_ms = age,
            } };
        } else if (std.mem.eql(u8, cmd, "%exit")) {
            // `%exit`, or `%exit <reason>`. tmux follows this with the
            // string terminator that ends the DCS, so the viewer would
            // find out either way; this is how it finds out *why*.
            const reason: ?[]const u8 = if (line.len > cmd.len + 1)
                line[cmd.len + 1 ..]
            else
                null;

            // Important: do not clear the buffer, reason points into it.
            self.state = .idle;
            return .{ .exit = reason };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            var re = oni.Regex.init(
                "^%window-add @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-close"))
        cmd: {
            var re = oni.Regex.init(
                "^%(?:unlinked-)?window-close @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_close = .{ .id = id } };
        } else if (std.mem.startsWith(u8, cmd, "%unlinked-window-")) {
            // A window appearing or being renamed somewhere else in the
            // server. Nothing to show for a window we are not attached
            // to. Parsed rather than left to the unknown fall-through so
            // the log stays quiet and the omission reads as deliberate.
            //
            // Note this does NOT cover `%unlinked-window-close`, which is
            // handled above: see the comment on the `window_close`
            // notification for why that one is ours.
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return null;
        } else if (std.mem.eql(u8, cmd, "%session-renamed")) cmd: {
            var re = oni.Regex.init(
                "^%session-renamed \\$([0-9]+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            var re = oni.Regex.init(
                // `(.*)`: renaming a window to nothing is legal, and
                // tmux then sends the separator with no name after it.
                "^%window-renamed @([0-9]+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%session-window-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-window-changed \\$([0-9]+) @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .session_window_changed = .{
                .session_id = session_id,
                .window_id = window_id,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            var re = oni.Regex.init(
                "^%window-pane-changed @([0-9]+) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            var re = oni.Regex.init(
                "^%client-detached (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%client-session-changed (.+) \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[3])..@intCast(ends[3])];

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%message")) {
            // The text of a `display-message` aimed at us. Free text,
            // spaces and all, so it is simply the rest of the line.
            //
            // Important: do not clear the buffer, the text points into it.
            self.state = .idle;
            return .{ .message = restOfLine(line, cmd) };
        } else if (std.mem.eql(u8, cmd, "%config-error")) {
            // An error from loading tmux.conf, as free text.
            //
            // Important: do not clear the buffer, the text points into it.
            self.state = .idle;
            return .{ .config_error = restOfLine(line, cmd) };
        } else if (std.mem.eql(u8, cmd, "%paste-buffer-changed") or
            std.mem.eql(u8, cmd, "%paste-buffer-deleted"))
        {
            // A buffer name is free text too.
            const name = restOfLine(line, cmd);

            // Important: do not clear the buffer, the name points into it.
            self.state = .idle;
            return if (std.mem.eql(u8, cmd, "%paste-buffer-changed"))
                .{ .paste_buffer_changed = .{ .name = name } }
            else
                .{ .paste_buffer_deleted = .{ .name = name } };
        } else if (std.mem.eql(u8, cmd, "%pane-mode-changed")) cmd: {
            const rest = restOfLine(line, cmd);
            if (rest.len < 2 or rest[0] != '%') {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pane_mode_changed = .{ .pane_id = id } };
        } else if (std.mem.eql(u8, cmd, "%subscription-changed")) cmd: {
            // `name $session @window index %pane ... : value`. The ids
            // are `-` for a subscription that is not about a window or
            // pane, and tmux(1) reserves room for more arguments before
            // the colon, so anything after the pane is ignored. The name
            // is the first argument (subscription names cannot contain a
            // space or a colon) and the value is everything after the
            // first " : ".
            const rest = restOfLine(line, cmd);
            const sep = std.mem.indexOf(u8, rest, " : ") orelse {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            };

            var args = std.mem.splitScalar(u8, rest[0..sep], ' ');
            const name = args.next() orelse unreachable;
            const session_id = prefixedId(args.next(), '$');
            const window_id = prefixedId(args.next(), '@');
            _ = args.next(); // The window's index in the session.
            const pane_id = prefixedId(args.next(), '%');

            // Important: do not clear the buffer, both point into it.
            self.state = .idle;
            return .{ .subscription_changed = .{
                .name = name,
                .session_id = session_id,
                .window_id = window_id,
                .pane_id = pane_id,
                .value = rest[sep + 3 ..],
            } };
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    /// Everything after a notification's name and the space following
    /// it, for notifications whose only argument is free text.
    fn restOfLine(line: []const u8, cmd: []const u8) []const u8 {
        return if (line.len > cmd.len + 1) line[cmd.len + 1 ..] else "";
    }

    /// An id written with its sigil, such as `@3`, or null for anything
    /// else: tmux writes `-` for an id that does not apply.
    fn prefixedId(arg: ?[]const u8, sigil: u8) ?usize {
        const s = arg orelse return null;
        if (s.len < 2 or s[0] != sigil) return null;
        return std.fmt.parseInt(usize, s[1..], 10) catch null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Decode the escaping tmux applies to text it can't send raw.
///
/// Two places need this and they use slightly different dialects of the
/// same encoding:
///
///   * `%output` payloads, where `control_write_pane_output` in tmux's
///     control.c writes any byte below a space, and the backslash itself,
///     as a backslash and three octal digits.
///   * `capture-pane -C` replies, where `grid_string_cells` in grid.c
///     writes escape sequences the same way (`\033[`, `\016`, `\017`) but
///     writes a literal backslash as a doubled backslash.
///
/// Decoding both here means neither caller has to care which it has. The
/// dialects can't collide: %output never emits a doubled backslash
/// because it octal-escapes that byte too.
///
/// Everything else passes through, so UTF-8 and other high bytes are
/// untouched.
///
/// The decoded form is never longer than what came in, so `dst` may alias
/// `src` to decode in place. Callers holding a mutable slice do exactly
/// that, which keeps the data pointing into the parser's own buffer.
pub fn unescape(dst: []u8, src: []const u8) []u8 {
    assert(dst.len >= src.len);

    var w: usize = 0;
    var r: usize = 0;

    while (r < src.len) {
        // Anything that cannot begin an escape is just a byte.
        if (src[r] != '\\' or r + 2 > src.len) {
            dst[w] = src[r];
            w += 1;
            r += 1;
            continue;
        }

        // A doubled backslash is one backslash.
        if (src[r + 1] == '\\') {
            dst[w] = '\\';
            w += 1;
            r += 2;
            continue;
        }

        const decoded: ?u8 = decoded: {
            if (r + 4 > src.len) break :decoded null;
            var value: u16 = 0;
            for (src[r + 1 ..][0..3]) |c| {
                if (c < '0' or c > '7') break :decoded null;
                value = value * 8 + (c - '0');
            }
            break :decoded std.math.cast(u8, value);
        };

        // Not an escape tmux would have written, so leave the backslash
        // alone rather than swallowing what follows it.
        const byte = decoded orelse {
            dst[w] = src[r];
            w += 1;
            r += 1;
            continue;
        };

        dst[w] = byte;
        w += 1;
        r += 4;
    }

    return dst[0..w];
}

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Control mode ended.
    ///
    /// Carries tmux's reason when it gave one. It is the only explanation
    /// we ever get for a session ending, and "too far behind" reads very
    /// differently from a clean detach when something has gone wrong, so
    /// the viewer passes it on to the user. It points into the parser's
    /// buffer and
    /// so is bounded by `max_line_bytes` like every other line.
    exit: ?[]const u8,

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: []const u8,
    block_err: []const u8,

    /// tmux stopped sending a pane's output and is discarding it until
    /// we ask for it to resume. Only happens with the pause-after client
    /// flag, which we never set -- but any other client can set it on us
    /// (`refresh-client -t <us> -f pause-after=N`), and a paused pane
    /// looks exactly like a frozen one.
    pause: struct {
        pane_id: usize,
    },

    /// tmux resumed a paused pane, acknowledging our request.
    @"continue": struct {
        pane_id: usize,
    },

    /// Raw output from a pane.
    output: struct {
        pane_id: usize,
        data: []const u8, // unescaped

        /// How long tmux held this before sending it, in milliseconds.
        /// Only present on `%extended-output`, which replaces `%output`
        /// wholesale once pause-after is on for our client.
        age_ms: ?u64 = null,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id closed, or left our session. tmux
    /// suppresses the dying window's `%layout-change`, so this is the
    /// only word we get that it is gone.
    ///
    /// Carries `%unlinked-window-close` as well as `%window-close`.
    /// `control_window_unlinked_cb` in tmux's control-notify.c picks
    /// between them by whether the window is still in the client's
    /// session, and by the time it runs for a window of ours it usually
    /// is not — killing a window in our own session is observed to send
    /// the unlinked form. Both mean the same thing to us, and re-listing
    /// for a window that was never ours is harmless.
    window_close: struct {
        id: usize,
    },

    /// Our session was renamed. Nothing depends on the session name yet,
    /// but it used to land in the unknown-notification bin, and a name
    /// with a space in it is exactly the sort of line that used to be
    /// worth worrying about.
    session_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    /// The session's current window changed. tmux sends this to every
    /// control client, including the one whose `select-window` caused it.
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },

    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    /// A message for this client, from `display-message` run against it
    /// without `-p`. tmux would show this on a normal client's status
    /// line.
    message: []const u8,

    /// An error from loading the tmux configuration file. A normal client
    /// would be shown these in a pane when it attaches.
    ///
    /// Note that tmux writes these as part of the reply to the command
    /// that attached, so the first ones usually arrive *inside* the
    /// initial `%begin` block rather than as a notification of their own;
    /// see the viewer's startup handling. This variant is the ones that
    /// do arrive on their own.
    config_error: []const u8,

    /// A paste buffer was created or changed.
    paste_buffer_changed: struct {
        name: []const u8,
    },

    /// A paste buffer was deleted.
    paste_buffer_deleted: struct {
        name: []const u8,
    },

    /// A pane entered or left a mode such as copy mode. Control clients
    /// are not sent what a pane in a mode looks like, only this.
    pane_mode_changed: struct {
        pane_id: usize,
    },

    /// A subscription set with `refresh-client -B` changed value.
    ///
    /// tmux checks subscriptions once a second and sends one of these per
    /// session, window or pane whose value differs from the last it sent
    /// this client, so the first check after subscribing reports every
    /// one of them. The ids say which one this is: a subscription to all
    /// panes (`%*`) has all three, one to all windows (`@*`) no pane, and
    /// one about the session neither a window nor a pane.
    subscription_changed: struct {
        name: []const u8,
        session_id: ?usize = null,
        window_id: ?usize = null,
        pane_id: ?usize = null,
        value: []const u8,
    },

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
        const info = @typeInfo(T).@"union";

        try writer.writeAll(@typeName(T));
        if (info.tag_type) |TagType| {
            try writer.writeAll("{ .");
            try writer.writeAll(@tagName(@as(TagType, self)));
            try writer.writeAll(" = ");

            inline for (info.fields) |u_field| {
                if (self == @field(TagType, u_field.name)) {
                    const value = @field(self, u_field.name);
                    switch (u_field.type) {
                        []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                        else => try writer.print("{any}", .{value}),
                    }
                }
            }

            try writer.writeAll(" }");
        }
    }
};

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}

test "tmux notification exactly max_line_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_line_bytes = line.len };
    defer c.deinit();

    // Twice, because the second '%' arrives while the buffer is still
    // full from the first notification.
    for (0..2) |_| {
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        const n = (try c.put('\n')).?;
        try testing.expect(n == .sessions_changed);
    }
}

test "tmux line limit applies per line of a block" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Every line fits, the block as a whole does not.
    const begin = "%begin 1 1 1";
    var c: Parser = .{ .buffer = .init(alloc), .max_line_bytes = begin.len };
    defer c.deinit();
    for (begin ++ "\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\nagain\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld\nagain", n.block_end);
}

test "tmux block line exceeding max_line_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc), .max_line_bytes = 16 };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("short\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("0123456789abcdef") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectError(error.OutOfMemory, c.put('g'));
    try testing.expect(try c.put('\n') == null);
}

test "tmux exceeding max_line_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_line_bytes = line.len - 1 };
    defer c.deinit();
    for (line[0 .. line.len - 1]) |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectError(error.OutOfMemory, c.put(line[line.len - 1]));
    try testing.expect(try c.put('\n') == null);
}

test "tmux block over max_block_bytes keeps its newest lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc), .max_block_bytes = 64 };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);

    // 100 lines of 7 bytes each, far more than the cap.
    var buf: [16]u8 = undefined;
    for (0..100) |i| {
        const line = try std.fmt.bufPrint(&buf, "line{d:0>2}\n", .{i});
        for (line) |byte| try testing.expect(try c.put(byte) == null);
    }

    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;

    // Not broken: the block ends and is still paired with its command.
    try testing.expect(n == .block_end);
    const out = n.block_end;
    try testing.expect(out.len <= 64);
    try testing.expect(out.len > 0);

    // Whole lines, newest last, with nothing missing in between.
    try testing.expect(std.mem.endsWith(u8, out, "line99"));
    try testing.expect(std.mem.startsWith(u8, out, "line"));
    var it = std.mem.splitScalar(u8, out, '\n');
    var prev: ?usize = null;
    while (it.next()) |line| {
        try testing.expectEqual(6, line.len);
        const num = try std.fmt.parseInt(usize, line[4..], 10);
        if (prev) |p_| try testing.expectEqual(p_ + 1, num);
        prev = num;
    }

    // And the parser is fine afterwards.
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect((try c.put('\n')).? == .sessions_changed);
}

test "tmux block over max_block_bytes with one long line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A single line longer than half the block cap is kept whole; only
    // the line limit can bound a line.
    var c: Parser = .{ .buffer = .init(alloc), .max_block_bytes = 16 };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("old\n" ++ "x" ** 20 ++ "\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("x" ** 20, n.block_end);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}

test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end);
}

test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end);
}

test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err);
}

test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end);
}

test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output unescapes control bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // How tmux writes a prompt redraw: carriage return, then an erase to
    // end of line. Every byte below a space arrives as three octal digits.
    for ("%output %0 a\\015\\033[Kb") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqualStrings("a\r\x1b[Kb", n.output.data);
}

test "tmux output unescapes a literal backslash" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // A backslash is itself escaped, so it is not mistaken for one.
    for ("%output %0 a\\134b") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\b", n.output.data);
}

test "tmux output leaves a stray backslash alone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Not something tmux emits, but decoding must not eat bytes or run
    // off the end when it sees one.
    for ("%output %0 a\\9z b\\01") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("a\\9z b\\01", n.output.data);
}

test "tmux output passes utf8 through" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // tmux only escapes bytes below a space, so high bytes arrive raw.
    for ("%output %0 caf\u{00e9}") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("caf\u{00e9}", n.output.data);
}

test "tmux unescape decodes a doubled backslash" {
    const testing = std.testing;

    // `capture-pane -C` writes a literal backslash as a doubled backslash
    // rather than the `\134` that %output uses.
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a\\b", unescape(&buf, "a\\\\b"));
}

test "tmux unescape decodes into a separate buffer" {
    const testing = std.testing;

    // Block payloads are const, so they decode out of place.
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b[31mX", unescape(&buf, "\\033[31mX"));
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux exit without a reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .exit);
    try testing.expectEqual(null, n.exit);
}

test "tmux exit with a reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // The reason tmux gives when it decides a control client is not
    // draining fast enough, and the only explanation we would ever get.
    for ("%exit too far behind") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqualStrings("too far behind", n.exit.?);
}

test "tmux survives a name containing a newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // `rename-window $'a\nb'` is enough to produce this. tmux does not
    // escape names, so the tail arrives as its own line starting with a
    // byte that cannot begin a notification.
    for ("%window-renamed @1 a") |byte| try testing.expect(try c.put(byte) == null);
    const renamed = (try c.put('\n')).?;
    try testing.expectEqualStrings("a", renamed.window_renamed.name);

    for ("b") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);

    // Still alive, and still parsing.
    for ("%window-add @7") |byte| try testing.expect(try c.put(byte) == null);
    const added = (try c.put('\n')).?;
    try testing.expectEqual(7, added.window_add.id);
}

test "tmux pause and continue" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    for ("%pause %5") |byte| try testing.expect(try c.put(byte) == null);
    const paused = (try c.put('\n')).?;
    try testing.expect(paused == .pause);
    try testing.expectEqual(5, paused.pause.pane_id);

    for ("%continue %5") |byte| try testing.expect(try c.put(byte) == null);
    const resumed = (try c.put('\n')).?;
    try testing.expect(resumed == .@"continue");
    try testing.expectEqual(5, resumed.@"continue".pane_id);
}

test "tmux extended-output is output with an age" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Once pause-after is on for a client, this replaces %output
    // wholesale. Same escaping, so it has to decode the same way.
    for ("%extended-output %3 1234 : a\\015b") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(3, n.output.pane_id);
    try testing.expectEqual(1234, n.output.age_ms.?);
    try testing.expectEqualStrings("a\rb", n.output.data);
}

test "tmux output has no age" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %0 hi") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqual(null, n.output.age_ms);
}

test "tmux window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-close @2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(2, n.window_close.id);
}

test "tmux unlinked window notifications are ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Not ours to care about, but the parser must stay healthy across
    // them: a live session gets these whenever anyone else's window
    // changes.
    for ("%unlinked-window-add @9") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);
    for ("%unlinked-window-renamed @9 other") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect(try c.put('\n') == null);

    for ("%window-close @3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expectEqual(3, n.window_close.id);
}

test "tmux unlinked-window-close is a window close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // What tmux actually sends when a window in our own session is
    // killed, because it has already been unlinked by the time the
    // notification callback runs.
    for ("%unlinked-window-close @1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(1, n.window_close.id);
}

test "tmux session-window-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    for ("%session-window-changed $2 @7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(2, n.session_window_changed.session_id);
    try testing.expectEqual(7, n.session_window_changed.window_id);
}

test "tmux session-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-renamed $3 my session") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_renamed);
    try testing.expectEqual(3, n.session_renamed.id);
    try testing.expectEqualStrings("my session", n.session_renamed.name);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}

/// Feed one complete line to a parser and return what it produced.
fn testLine(c: *Parser, line: []const u8) !?Notification {
    for (line) |byte| try std.testing.expect(try c.put(byte) == null);
    return try c.put('\n');
}

test "tmux window-renamed to nothing" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    // Exactly what tmux 3.6 sends for `rename-window ''`: the separator
    // and no name.
    const n = (try testLine(&c, "%window-renamed @0 ")).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(0, n.window_renamed.id);
    try testing.expectEqualStrings("", n.window_renamed.name);
}

test "tmux extended-output tolerates arguments it does not know" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const n = (try testLine(&c, "%extended-output %3 12 future args : a : b")).?;
    try testing.expect(n == .output);
    try testing.expectEqual(3, n.output.pane_id);
    try testing.expectEqual(12, n.output.age_ms.?);
    try testing.expectEqualStrings("a : b", n.output.data);
}

test "tmux message" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const n = (try testLine(&c, "%message hello from display")).?;
    try testing.expect(n == .message);
    try testing.expectEqualStrings("hello from display", n.message);
}

test "tmux config-error" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const n = (try testLine(
        &c,
        "%config-error /home/me/.tmux.conf:2: unknown command: nope",
    )).?;
    try testing.expect(n == .config_error);
    try testing.expectEqualStrings(
        "/home/me/.tmux.conf:2: unknown command: nope",
        n.config_error,
    );
}

test "tmux paste buffer notifications" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const changed = (try testLine(&c, "%paste-buffer-changed buffer0")).?;
    try testing.expect(changed == .paste_buffer_changed);
    try testing.expectEqualStrings("buffer0", changed.paste_buffer_changed.name);

    const deleted = (try testLine(&c, "%paste-buffer-deleted my buf")).?;
    try testing.expect(deleted == .paste_buffer_deleted);
    try testing.expectEqualStrings("my buf", deleted.paste_buffer_deleted.name);
}

test "tmux pane-mode-changed" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const n = (try testLine(&c, "%pane-mode-changed %7")).?;
    try testing.expect(n == .pane_mode_changed);
    try testing.expectEqual(7, n.pane_mode_changed.pane_id);

    // Malformed is dropped, not fatal.
    try testing.expect(try testLine(&c, "%pane-mode-changed @7") == null);
    try testing.expect((try testLine(&c, "%sessions-changed")).? == .sessions_changed);
}

test "tmux subscription-changed" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    const pane = (try testLine(&c, "%subscription-changed sub1 $0 @0 0 %0 : cat : x")).?;
    try testing.expect(pane == .subscription_changed);
    try testing.expectEqualStrings("sub1", pane.subscription_changed.name);
    try testing.expectEqualStrings("cat : x", pane.subscription_changed.value);
    try testing.expectEqual(0, pane.subscription_changed.session_id);
    try testing.expectEqual(0, pane.subscription_changed.window_id);
    try testing.expectEqual(0, pane.subscription_changed.pane_id);

    const window = (try testLine(&c, "%subscription-changed w $2 @7 3 - : 100")).?;
    try testing.expectEqualStrings("w", window.subscription_changed.name);
    try testing.expectEqual(2, window.subscription_changed.session_id);
    try testing.expectEqual(7, window.subscription_changed.window_id);
    try testing.expectEqual(null, window.subscription_changed.pane_id);
    try testing.expectEqualStrings("100", window.subscription_changed.value);

    const session = (try testLine(&c, "%subscription-changed s2 $1 - - - : ")).?;
    try testing.expectEqualStrings("s2", session.subscription_changed.name);
    try testing.expectEqual(1, session.subscription_changed.session_id);
    try testing.expectEqual(null, session.subscription_changed.window_id);
    try testing.expectEqual(null, session.subscription_changed.pane_id);
    try testing.expectEqualStrings("", session.subscription_changed.value);

    // Arguments a later tmux adds before the colon are not ids.
    const future = (try testLine(&c, "%subscription-changed f $0 @1 0 %4 extra : v")).?;
    try testing.expectEqual(4, future.subscription_changed.pane_id);
    try testing.expectEqualStrings("v", future.subscription_changed.value);
}

test "tmux every 3.6 notification parses without breaking the parser" {
    const testing = std.testing;
    var c: Parser = .{ .buffer = .init(testing.allocator) };
    defer c.deinit();

    // A transcript of the notifications tmux 3.6 can send, as captured
    // from a real server. Every one must leave the parser able to read
    // the next, and all but the deliberately ignored unlinked add and
    // rename must produce a notification.
    const lines = [_][]const u8{
        "%client-detached /dev/ttys004",
        "%client-session-changed /dev/ttys004 $1 other",
        "%config-error /tmp/bad.conf:2: unknown command: nope",
        "%continue %0",
        "%extended-output %0 5 : x",
        "%layout-change @0 b25d,80x24,0,0,0 b25d,80x24,0,0,0 *",
        "%message hi",
        "%output %0 x",
        "%pane-mode-changed %0",
        "%paste-buffer-changed buffer0",
        "%paste-buffer-deleted buffer0",
        "%pause %0",
        "%session-changed $0 0",
        "%session-renamed $0 renamed sess",
        "%session-window-changed $0 @0",
        "%sessions-changed",
        "%subscription-changed sub1 $0 @0 0 %0 : cat",
        "%unlinked-window-add @1",
        "%unlinked-window-close @1",
        "%unlinked-window-renamed @1",
        "%window-add @1",
        "%window-close @1",
        "%window-pane-changed @0 %3",
        "%window-renamed @0 ",
    };
    for (lines) |line| {
        const n = try testLine(&c, line);
        try testing.expect(c.state == .idle);

        const ignored = std.mem.startsWith(u8, line, "%unlinked-window-add") or
            std.mem.startsWith(u8, line, "%unlinked-window-renamed");
        try testing.expect(ignored == (n == null));
    }

    // And a block still works after all of that.
    try testing.expect(try testLine(&c, "%begin 1 1 1") == null);
    const n = (try testLine(&c, "%end 1 1 1")).?;
    try testing.expect(n == .block_end);
}
