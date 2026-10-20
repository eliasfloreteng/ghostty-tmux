//! tmux's passthrough escape, `DCS tmux; ... ST`, taken back out of a
//! pane's output.
//!
//! A program inside tmux that wants to reach the terminal outside it,
//! rather than the terminal tmux emulates for it, wraps the sequence:
//! `ESC P tmux;` then the sequence with every ESC doubled, then `ESC \`.
//! For a tty client, tmux unwraps it (an ESC followed by anything but `\`
//! stands for that byte alone) and writes the inner sequence to the
//! client's terminal as is, but only while the pane's `allow-passthrough`
//! option is on. Programs use it for what tmux would otherwise swallow or
//! rewrite: desktop notifications (Claude Code wraps its OSC 9, OSC 99 and
//! OSC 777 notifications whenever `$TMUX` is set), clipboard writes,
//! images.
//!
//! A control client gets none of that. Its `%output` is the pane's output
//! exactly as the program wrote it, before tmux has parsed any of it, so
//! the wrapper arrives still wrapped -- whatever `allow-passthrough` says,
//! which only gates tmux's own writes to tty clients (tmux 3.6,
//! `input_dcs_dispatch` and `control_write_output`). Left alone, our
//! parser would end the DCS at the first doubled ESC and stumble through
//! the rest. So this takes it apart again, before the parser sees it.
//!
//! The option is not consulted, and not changed on attach: everything a
//! program could send wrapped it can already send to us unwrapped, since
//! tmux forwards a control client the raw output either way. The wrapper
//! grants nothing here that `allow-passthrough` exists to withhold.
//!
//! What comes out of the wrapper is not trusted with the grid, though.
//! tmux never sees it take effect, so text, cursor movement or a mode
//! change inside it would leave our copy of the pane different from
//! tmux's, with nothing to ever bring the two back together. Only the
//! string sequences survive: OSC, DCS and APC, which is everything
//! programs actually wrap (notifications, clipboard, kitty graphics). The
//! rest is dropped, as tmux's own grid drops it.

const std = @import("std");
const testing = std.testing;

/// What opens a passthrough. tmux matches it exactly: the DCS has no
/// parameters or intermediates and its data starts with `tmux;`.
const prefix = "\x1bPtmux;";

/// Where a run of unwrapped output belongs.
pub const Kind = enum {
    /// The pane's own output, for its terminal and tmux's alike.
    pane,

    /// A string sequence the program wrapped for the terminal outside
    /// tmux. Never prints, but must go through the same parser as the
    /// pane's output: it can be split across runs, and across `feed`s.
    passthrough,
};

pub const Unwrapper = struct {
    state: State = .ground,

    /// How far we are into the sequence inside the wrapper.
    inner: Inner = .ground,

    const State = union(enum) {
        /// The pane's own output.
        ground,

        /// This many bytes of `prefix` have been seen and held back,
        /// in case they turn out to open a passthrough.
        prefix: u3,

        /// Inside a passthrough.
        body,

        /// Inside a passthrough, just past an ESC: either the end of the
        /// passthrough, or an escaped byte.
        body_esc,
    };

    const Inner = enum {
        /// Between sequences. Anything here is not a string sequence and
        /// is dropped.
        ground,

        /// Past an ESC, which is only passed on if a string follows.
        esc,

        /// Inside an OSC, which a BEL also ends.
        osc,

        /// Inside a DCS or APC.
        string,

        /// Inside a string, just past an ESC.
        string_esc,
    };

    /// Whether nothing is held back or open: no partial prefix, and no
    /// passthrough or wrapped sequence under way.
    pub fn idle(self: *const Unwrapper) bool {
        return self.state == .ground and self.inner == .ground;
    }

    /// Whether a string sequence from a passthrough is open, so that the
    /// next passthrough run continues it. Something that starts parsing
    /// this pane's output now would see that continuation without its
    /// start, and print it.
    pub fn midSequence(self: *const Unwrapper) bool {
        return switch (self.inner) {
            .osc, .string, .string_esc => true,
            .ground, .esc => false,
        };
    }

    /// Unwrap `input`, handing each run to `handler.emit(kind, bytes)` in
    /// order. A run is only valid for the duration of the call: it may
    /// point into `input` or into constants.
    ///
    /// State carries over between calls, since tmux splits output
    /// wherever the pane's writes landed. A partial prefix at the end of
    /// `input` is held back until the next call says what it was.
    pub fn feed(
        self: *Unwrapper,
        input: []const u8,
        handler: anytype,
    ) !void {
        var i: usize = 0;
        while (i < input.len) {
            switch (self.state) {
                .ground => {
                    // The pane's output runs up to the next ESC that opens
                    // a passthrough, as one slice of `input`, however many
                    // other escape sequences are in it: a TUI's output is
                    // mostly escape sequences, and splitting at each would
                    // hand the parser and every display a run per colour.
                    // Only a prefix the input ends part way into has to be
                    // held back to find out what it is.
                    var pos = i;
                    const esc = while (std.mem.indexOfScalarPos(
                        u8,
                        input,
                        pos,
                        0x1B,
                    )) |esc| {
                        const seen = @min(input.len - esc, prefix.len);
                        if (std.mem.eql(
                            u8,
                            input[esc..][0..seen],
                            prefix[0..seen],
                        )) break esc;
                        pos = esc + 1;
                    } else input.len;

                    if (esc > i) try self.pane(input[i..esc], handler);
                    if (esc == input.len) return;

                    const seen = @min(input.len - esc, prefix.len);
                    if (seen < prefix.len) {
                        self.state = .{ .prefix = @intCast(seen) };
                        return;
                    }

                    // `inner` is left as it was: see `.prefix`.
                    self.state = .body;
                    i = esc + prefix.len;
                },

                .prefix => |n| {
                    if (input[i] != prefix[n]) {
                        // Not ours after all. What we held goes out as
                        // it came, and this byte is looked at afresh: it
                        // may be the ESC of a real prefix.
                        self.state = .ground;
                        try self.pane(prefix[0..n], handler);
                        continue;
                    }

                    i += 1;
                    if (n + 1 < prefix.len) {
                        self.state = .{ .prefix = n + 1 };
                        continue;
                    }

                    // `inner` is left as it was: a sequence too long for
                    // one passthrough can be split across several, as
                    // programs that also support GNU screen do.
                    self.state = .body;
                },

                .body => {
                    if (input[i] == 0x1B) {
                        self.state = .body_esc;
                        i += 1;
                        continue;
                    }

                    // Inside a string, everything up to a byte that could
                    // end it goes out as one run: image data is long.
                    if (self.inner == .osc or self.inner == .string) {
                        const end = std.mem.indexOfAnyPos(
                            u8,
                            input,
                            i,
                            "\x1b\x07\x18\x1a",
                        ) orelse input.len;
                        if (end > i) {
                            try handler.emit(.passthrough, input[i..end]);
                            i = end;
                            continue;
                        }
                    }

                    try self.innerByte(input[i .. i + 1], handler);
                    i += 1;
                },

                .body_esc => {
                    i += 1;
                    if (input[i - 1] == '\\') {
                        self.state = .ground;
                        continue;
                    }

                    // tmux's escape: ESC then any other byte is that byte.
                    self.state = .body;
                    try self.innerByte(input[i - 1 .. i], handler);
                },
            }
        }
    }

    /// The pane's own output. Abandons a string a passthrough left open,
    /// so that it cannot swallow what comes next.
    fn pane(self: *Unwrapper, bytes: []const u8, handler: anytype) !void {
        switch (self.inner) {
            .ground => {},
            .esc => self.inner = .ground,
            .osc, .string, .string_esc => {
                // CAN aborts a string without dispatching it.
                try handler.emit(.passthrough, "\x18");
                self.inner = .ground;
            },
        }

        try handler.emit(.pane, bytes);
    }

    /// One unescaped byte from inside a passthrough. `byte` is a slice
    /// of the input holding just it, so it can be emitted without a copy.
    fn innerByte(self: *Unwrapper, byte: []const u8, handler: anytype) !void {
        const c = byte[0];
        state: switch (self.inner) {
            .ground => if (c == 0x1B) {
                self.inner = .esc;
            },

            .esc => switch (c) {
                ']' => {
                    try handler.emit(.passthrough, "\x1b]");
                    self.inner = .osc;
                },
                'P' => {
                    try handler.emit(.passthrough, "\x1bP");
                    self.inner = .string;
                },
                '_' => {
                    try handler.emit(.passthrough, "\x1b_");
                    self.inner = .string;
                },
                0x1B => {},
                else => self.inner = .ground,
            },

            .osc, .string => switch (c) {
                0x1B => self.inner = .string_esc,
                0x07 => {
                    try handler.emit(.passthrough, byte);
                    if (self.inner == .osc) self.inner = .ground;
                },
                0x18, 0x1A => {
                    try handler.emit(.passthrough, byte);
                    self.inner = .ground;
                },
                else => try handler.emit(.passthrough, byte),
            },

            .string_esc => {
                // An ESC ends a string whatever follows it. Give the
                // parser a proper terminator, then let the byte start
                // whatever it starts.
                try handler.emit(.passthrough, "\x1b\\");
                if (c == '\\') {
                    self.inner = .ground;
                    return;
                }
                self.inner = .esc;
                continue :state .esc;
            },
        }
    }
};

/// Collects runs for tests, merging neighbours of the same kind so that
/// expectations do not depend on where runs happen to split.
const TestCollector = struct {
    alloc: std.mem.Allocator,
    runs: std.ArrayList(struct { kind: Kind, bytes: std.ArrayList(u8) }) = .empty,

    /// Every call to `emit`, before adjacent runs of a kind are joined:
    /// how finely the output was cut.
    emits: usize = 0,

    fn deinit(self: *TestCollector) void {
        for (self.runs.items) |*r| r.bytes.deinit(self.alloc);
        self.runs.deinit(self.alloc);
    }

    pub fn emit(self: *TestCollector, kind: Kind, bytes: []const u8) !void {
        self.emits += 1;
        if (self.runs.items.len == 0 or
            self.runs.items[self.runs.items.len - 1].kind != kind)
        {
            try self.runs.append(self.alloc, .{ .kind = kind, .bytes = .empty });
        }
        const last = &self.runs.items[self.runs.items.len - 1];
        try last.bytes.appendSlice(self.alloc, bytes);
    }

    fn expect(self: *const TestCollector, expected: []const struct { Kind, []const u8 }) !void {
        try testing.expectEqual(expected.len, self.runs.items.len);
        for (expected, self.runs.items) |e, r| {
            try testing.expectEqual(e[0], r.kind);
            try testing.expectEqualStrings(e[1], r.bytes.items);
        }
    }
};

fn unwrapAll(chunks: []const []const u8, c: *TestCollector) !Unwrapper {
    var u: Unwrapper = .{};
    for (chunks) |chunk| try u.feed(chunk, c);
    return u;
}

test "output without a passthrough is left alone" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    _ = try unwrapAll(&.{"hello \x1b[1mworld\x1b]0;title\x07\x1bPq#0\x1b\\"}, &c);
    try c.expect(&.{
        .{ .pane, "hello \x1b[1mworld\x1b]0;title\x07\x1bPq#0\x1b\\" },
    });
}

test "a wrapped notification is unwrapped" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();

    // What Claude Code writes for its Ghostty notification under tmux.
    _ = try unwrapAll(&.{
        "a\x1bPtmux;\x1b\x1b]777;notify;Claude Code;done\x1b\x1b\\\x1b\\b",
    }, &c);
    try c.expect(&.{
        .{ .pane, "a" },
        .{ .passthrough, "\x1b]777;notify;Claude Code;done\x1b\\" },
        .{ .pane, "b" },
    });
}

test "a BEL ends a wrapped OSC" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    _ = try unwrapAll(&.{"\x1bPtmux;\x1b\x1b]9;hi\x07\x1b\\"}, &c);
    try c.expect(&.{.{ .passthrough, "\x1b]9;hi\x07" }});
}

test "a passthrough split anywhere unwraps the same" {
    const whole = "x\x1bPtmux;\x1b\x1b]99;i=1;title\x1b\x1b\\\x1b\\y";
    for (1..whole.len) |split| {
        var c: TestCollector = .{ .alloc = testing.allocator };
        defer c.deinit();
        _ = try unwrapAll(&.{ whole[0..split], whole[split..] }, &c);
        try c.expect(&.{
            .{ .pane, "x" },
            .{ .passthrough, "\x1b]99;i=1;title\x1b\\" },
            .{ .pane, "y" },
        });
    }
}

test "something that only starts like a passthrough is the pane's" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    _ = try unwrapAll(&.{ "\x1bPtm", "ox;data\x1b\\" }, &c);
    try c.expect(&.{.{ .pane, "\x1bPtmox;data\x1b\\" }});
}

test "a held ESC that starts a real passthrough" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    _ = try unwrapAll(&.{"\x1bP\x1bPtmux;\x1b\x1b]9;a\x07\x1b\\"}, &c);
    try c.expect(&.{
        .{ .pane, "\x1bP" },
        .{ .passthrough, "\x1b]9;a\x07" },
    });
}

test "only string sequences come out of a passthrough" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();

    // Text, a cursor move and a mode change would all change our grid
    // behind tmux's back. A kitty graphics APC is kept.
    _ = try unwrapAll(&.{
        "\x1bPtmux;text\x1b\x1b[5;5H\x1b\x1b[?25l\x1b\x1b_Gf=100;AAAA\x1b\x1b\\more\x1b\\",
    }, &c);
    try c.expect(&.{.{ .passthrough, "\x1b_Gf=100;AAAA\x1b\\" }});
}

test "a string split across passthroughs continues" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();

    // GNU screen needs long sequences chunked, and some programs chunk
    // for tmux too.
    const u = try unwrapAll(&.{
        "\x1bPtmux;\x1b\x1b_Gm=1;AA\x1b\\",
        "\x1bPtmux;BB\x1b\x1b\\\x1b\\",
    }, &c);
    try c.expect(&.{.{ .passthrough, "\x1b_Gm=1;AABB\x1b\\" }});
    try testing.expect(!u.midSequence());
}

test "pane output abandons a string a passthrough left open" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    var u: Unwrapper = .{};
    try u.feed("\x1bPtmux;\x1b\x1b]9;unfinished\x1b\\", &c);
    try testing.expect(u.midSequence());
    try u.feed("prompt$ ", &c);
    try testing.expect(!u.midSequence());
    try c.expect(&.{
        .{ .passthrough, "\x1b]9;unfinished\x18" },
        .{ .pane, "prompt$ " },
    });
}

test "an ESC inside a wrapped string ends it" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();

    // Two sequences back to back, the first ended by the ESC of the
    // second rather than by ST.
    _ = try unwrapAll(&.{"\x1bPtmux;\x1b\x1b]9;a\x1b\x1b]9;b\x07\x1b\\"}, &c);
    try c.expect(&.{.{ .passthrough, "\x1b]9;a\x1b\\\x1b]9;b\x07" }});
}

test "a pane's escape sequences come out as one run, in place" {
    // A TUI's repaint: colours, cursor moves, an OSC, and a DCS that is
    // not tmux's, with no passthrough anywhere.
    const input = "\x1b[?2026h\x1b[1;1H\x1b[32m\xe2\x94\x82\x1b[m\x0f row\x1b[K" ++
        "\x1b]0;t\x07\x1bPq#0\x1b\\\x1bP\x1bPt\x1b[?2026l";

    const Recorder = struct {
        input: []const u8,
        calls: usize = 0,

        pub fn emit(self: *@This(), kind: Kind, bytes: []const u8) !void {
            self.calls += 1;
            try testing.expectEqual(Kind.pane, kind);
            // A slice of the input itself, not a copy or a constant.
            try testing.expectEqual(self.input.ptr, bytes.ptr);
            try testing.expectEqual(self.input.len, bytes.len);
        }
    };

    var r: Recorder = .{ .input = input };
    var u: Unwrapper = .{};
    try u.feed(input, &r);
    try testing.expectEqual(1, r.calls);
    try testing.expect(u.idle());
}

test "pane output either side of a passthrough is a run each" {
    var c: TestCollector = .{ .alloc = testing.allocator };
    defer c.deinit();
    _ = try unwrapAll(&.{
        "\x1b[31ma\x1b[m\x1bPtmux;\x1b\x1b]9;hi\x07\x1b\\\x1b[2Jb\x1b[H",
    }, &c);
    try c.expect(&.{
        .{ .pane, "\x1b[31ma\x1b[m" },
        .{ .passthrough, "\x1b]9;hi\x07" },
        .{ .pane, "\x1b[2Jb\x1b[H" },
    });
    // Left of it, the wrapped OSC (its start, body and BEL), right of it.
    try testing.expectEqual(5, c.emits);
}

test "an input ending part way into a prefix holds only the prefix back" {
    inline for (1..prefix.len) |held| {
        var c: TestCollector = .{ .alloc = testing.allocator };
        defer c.deinit();

        var u: Unwrapper = .{};
        try u.feed("\x1b[1mbold" ++ prefix[0..held], &c);
        try c.expect(&.{.{ .pane, "\x1b[1mbold" }});
        try testing.expect(!u.idle());

        // It was a passthrough after all.
        try u.feed(prefix[held..] ++ "\x1b\x1b]9;x\x07\x1b\\after", &c);
        try c.expect(&.{
            .{ .pane, "\x1b[1mbold" },
            .{ .passthrough, "\x1b]9;x\x07" },
            .{ .pane, "after" },
        });
        try testing.expect(u.idle());
    }
}

test "a held prefix that turns out not to be ours is given back whole" {
    inline for (1..prefix.len) |held| {
        var c: TestCollector = .{ .alloc = testing.allocator };
        defer c.deinit();
        // The byte after the held part breaks the prefix, and is itself
        // an ESC starting a colour.
        _ = try unwrapAll(&.{
            "a" ++ prefix[0..held],
            "\x1b[1mb",
        }, &c);
        try c.expect(&.{.{ .pane, "a" ++ prefix[0..held] ++ "\x1b[1mb" }});
    }
}
