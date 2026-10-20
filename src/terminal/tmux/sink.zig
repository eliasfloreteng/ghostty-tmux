//! Structured replay of a tmux pane onto a terminal the viewer does not own.
//!
//! The viewer keeps a shadow `Terminal` per pane. To render a pane in a real
//! surface, that surface's own terminal has to end up in the same state. The
//! obvious way to do that is to tee the pane's VT bytes, but the viewer's
//! replay is not only bytes: it also calls `switchScreen`, scrolls the active
//! area into history, erases the display, and writes cursor state onto the
//! *inactive* screen. Two of those have no escape sequence that reproduces
//! them:
//!
//!   * `Terminal.switchScreen` is the bare flip. Every mode-driven switch
//!     (DECSET 47, 1047, 1049) additionally copies the cursor, and 1049 also
//!     saves the cursor and erases the alternate screen. The viewer wants
//!     none of that.
//!
//!   * `applyPaneState` writes the alternate screen's cursor while the
//!     primary screen may be active. A byte stream only ever reaches the
//!     active screen.
//!
//! So the sink carries operations rather than bytes, with raw VT as one of
//! them. The viewer applies each op to its shadow terminal through the same
//! `applyOp` it hands to the sink, which is what keeps the two from drifting:
//! there is one implementation, not two.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;

const Terminal = @import("../Terminal.zig");
const ScreenSet = @import("../ScreenSet.zig");
const size = @import("../size.zig");
const viewer = @import("viewer.zig");

const log = std.log.scoped(.terminal_tmux_sink);

/// The parsed `list-panes` line for one pane.
pub const PaneStateData = viewer.PaneStateData;

/// A single operation on a pane's terminal.
///
/// Slices are only valid for the duration of the sink call: they point into
/// the viewer's notification and arena memory, the same contract the viewer's
/// actions carry. Copy anything you need to keep.
/// Which windows a "close tab" applies to.
///
/// Lives here rather than on the viewer's input because the router
/// carries it and cannot import the viewer without a cycle.
pub const KillScope = enum {
    /// Just the window the surface is in.
    this,
    /// Every window except that one.
    others,
    /// Every window after it, in tmux's order.
    right,
};

/// Where a new pane goes relative to the one being split.
///
/// Lives here for the same reason as `KillScope`.
pub const SplitDirection = enum {
    /// To the right: tmux's `-h`.
    right,
    /// To the left: `-h -b`, the new pane before the old one.
    left,
    /// Below: tmux's `-v`.
    down,
    /// Above: `-v -b`.
    up,
};

pub const Op = union(enum) {
    /// Raw VT bytes: `%output` data, or capture-pane replay content.
    ///
    /// These must go through a stream whose parser state persists across
    /// ops, because a sequence can be split across notifications.
    bytes: []const u8,

    /// VT bytes that are a capture of the pane rather than its output:
    /// the replay of a `capture-pane` reply.
    ///
    /// Parsed on their own, by a parser of their own, rather than by the
    /// stream the pane's output goes through. A capture is a snapshot
    /// taken between two `%output` notifications, and tmux cuts output
    /// wherever its read of the pty ended, so the pane's stream can be
    /// part way through an escape sequence when a capture arrives. Fed
    /// through that stream, the capture's first escape would abort the
    /// sequence, and its tail, arriving in the next notification, would
    /// be printed as text (the `;79;82;88m` left on screen by a resize
    /// that landed in the middle of a colour). Kept apart, the live
    /// sequence resumes where it was once the capture is in.
    replay: []const u8,

    /// Make the given screen active, without any of the side effects that
    /// the DECSET alternate-screen modes carry.
    switch_screen: ScreenSet.Key,

    /// Push the whole active area into scrollback and home the cursor. This
    /// is the tail of a history replay, and uses the applying terminal's own
    /// row count.
    scroll_into_history,

    /// Clear the display and home the cursor, ahead of a visible replay.
    erase_and_home,

    /// Clear the display and the scrollback, and home the cursor, ahead
    /// of a history replay.
    ///
    /// A history capture is all of the pane's history, not what is new
    /// since we last looked, and a pane can be read more than once: a
    /// paused pane is read again when it resumes, and a session switch
    /// can land on a pane whose display is still up. So the replay
    /// replaces what the terminal holds rather than adding to it.
    ///
    /// Only content goes. Modes, colors, the title and the like stay,
    /// because a capture does not carry them and some (bracketed paste,
    /// the kitty keyboard flags) tmux has no way to tell us again.
    erase_all,

    /// Turn the blanks a capture padded each row out with back into the
    /// empty cells they were.
    ///
    /// A capture without `-N` stops each row at its last non-blank cell,
    /// which throws away every trailing cell painted only with a
    /// background or reverse video: the bar along the bottom of a TUI,
    /// a highlighted selection line, a panel's fill. The program drew
    /// those once and has no reason to draw them again, so they stay
    /// missing. `-N` keeps them, but as spaces in whatever style was
    /// current, and spaces are text: they would be copied with a
    /// selection and carried by a reflow. So the visible captures ask
    /// for `-N` and follow their replay with this, which empties every
    /// trailing space with the default style on rows that do not wrap,
    /// leaving exactly the cells a trimmed capture would have left plus
    /// the styled ones it would have lost.
    trim_trailing_blanks,

    /// Cursor position, modes, scroll region and tab stops, as tmux
    /// reported them.
    pane_state: PaneStateData,

    /// The pane's grid was resized by a layout change.
    ///
    /// A consumer that owns a surface should route this through its surface
    /// resize path rather than letting `applyOp` resize the terminal alone,
    /// otherwise the renderer keeps a stale cell geometry.
    resize: struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    },

    /// Copy an op so it can outlive the sink call that delivered it.
    ///
    /// A sink that hands ops to another thread has to do this: the
    /// payloads point into the viewer's notification and arena memory.
    pub fn clone(self: Op, alloc: Allocator) Allocator.Error!Op {
        return switch (self) {
            .bytes => |b| .{ .bytes = try alloc.dupe(u8, b) },
            .replay => |b| .{ .replay = try alloc.dupe(u8, b) },

            // The parsed pane state is a flat struct of scalars and
            // slices, so walk it rather than naming the string fields:
            // tmux keeps adding columns, and a missed one here is a
            // dangling pointer rather than a compile error.
            .pane_state => |data| state: {
                var copy = data;
                errdefer freePaneState(alloc, copy, data);
                inline for (@typeInfo(PaneStateData).@"struct".fields) |f| {
                    if (comptime f.type == []const u8) {
                        @field(copy, f.name) = try alloc.dupe(
                            u8,
                            @field(data, f.name),
                        );
                    }
                }
                break :state .{ .pane_state = copy };
            },

            .switch_screen,
            .scroll_into_history,
            .erase_and_home,
            .erase_all,
            .trim_trailing_blanks,
            .resize,
            => self,
        };
    }

    /// Free an op produced by `clone`. Never call this on an op that came
    /// straight from the viewer; those payloads are not ours.
    pub fn deinit(self: Op, alloc: Allocator) void {
        switch (self) {
            .bytes, .replay => |b| alloc.free(b),
            .pane_state => |data| freePaneState(alloc, data, null),
            else => {},
        }
    }

    /// Free the duped strings of `copy`, skipping any field that is still
    /// aliasing `original` because `clone` had not reached it yet.
    fn freePaneState(
        alloc: Allocator,
        copy: PaneStateData,
        original: ?PaneStateData,
    ) void {
        inline for (@typeInfo(PaneStateData).@"struct".fields) |f| {
            if (comptime f.type == []const u8) {
                const field = @field(copy, f.name);
                const skip = if (original) |o|
                    field.ptr == @field(o, f.name).ptr
                else
                    false;
                if (!skip) alloc.free(field);
            }
        }
    }
};

/// A consumer of a pane's operations.
///
/// `ops` is called while the viewer's caller holds its renderer lock, so an
/// implementation must not block, and must not call into another terminal's
/// I/O: copy or enqueue and return.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ops: *const fn (ctx: *anyopaque, ops: []const Op) void,

        /// The pane is gone, or was detached. Never called concurrently
        /// with `ops`, and nothing is delivered afterwards.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub inline fn send(self: Sink, ops: []const Op) void {
        self.vtable.ops(self.ctx, ops);
    }

    pub inline fn close(self: Sink) void {
        self.vtable.close(self.ctx);
    }
};

/// Apply an op to a terminal.
///
/// `.bytes` is not handled here: the caller owns the stream, because parser
/// state has to persist across calls.
pub fn applyOp(
    alloc: Allocator,
    t: *Terminal,
    op: Op,
) !void {
    switch (op) {
        .bytes => unreachable,

        .replay => |b| {
            // The pen too is the live stream's and not the capture's:
            // the program in the pane chose the colours it is drawing
            // with and will not say so again, so whatever the capture
            // last set must not outlive it.
            const screen = t.screens.active;
            const pen = screen.cursor.style;
            {
                var stream = t.vtStream();
                defer stream.deinit();
                stream.nextSlice(b);
            }
            assert(screen == t.screens.active);
            screen.cursor.style = pen;
            try screen.manualStyleUpdate();
        },

        .switch_screen => |key| _ = try t.switchScreen(key),

        .scroll_into_history => {
            t.carriageReturn();
            for (0..t.rows) |_| try t.index();
            t.setCursorPos(1, 1);
        },

        .erase_and_home => {
            t.eraseDisplay(.complete, false);
            t.setCursorPos(1, 1);
        },

        .erase_all => {
            t.eraseDisplay(.complete, false);
            t.eraseDisplay(.scrollback, false);
            t.setCursorPos(1, 1);
        },

        .trim_trailing_blanks => trimTrailingBlanks(t),

        .pane_state => |data| try applyPaneState(t, data),

        .resize => |v| try t.resize(alloc, .{
            .cols = v.cols,
            .rows = v.rows,
        }),
    }
}

/// See `Op.trim_trailing_blanks`. Only the active area of the active
/// screen: that is where a visible capture lands.
fn trimTrailingBlanks(t: *Terminal) void {
    const screen = t.screens.active;
    for (0..t.rows) |y| {
        const pin = screen.pages.pin(.{ .active = .{
            .y = @intCast(y),
        } }) orelse continue;

        // A wrapped row's trailing spaces are part of its line, and a
        // full one has nothing trailing to trim.
        if (pin.rowAndCell().row.wrap) continue;

        const cells = pin.cells(.all);
        var x = cells.len;
        while (x > 0) : (x -= 1) {
            const cell = &cells[x - 1];
            if (cell.content_tag != .codepoint or
                cell.content.codepoint.data != ' ' or
                cell.style_id != 0 or
                cell.hyperlink or
                cell.wide != .narrow) break;
            cell.content.codepoint.data = 0;
        }
    }
}

/// Apply tmux's reported pane state to a terminal.
///
/// This is a merge, not a snapshot: an unrecognized cursor shape leaves the
/// shape alone, and out-of-range coordinates are skipped, because tmux sends
/// MAX_INT for "no saved cursor".
pub fn applyPaneState(t: *Terminal, data: PaneStateData) !void {
    // Determine which screen to use based on alternate_on
    const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

    // Restore the active screen reported by tmux.
    _ = try t.switchScreen(screen_key);

    // Set cursor position on the appropriate screen (tmux uses 0-based)
    if (t.screens.get(screen_key)) |screen| {
        cursor: {
            const cursor_x = std.math.cast(
                size.CellCountInt,
                data.cursor_x,
            ) orelse break :cursor;
            const cursor_y = std.math.cast(
                size.CellCountInt,
                data.cursor_y,
            ) orelse break :cursor;
            if (cursor_x >= screen.pages.cols or
                cursor_y >= screen.pages.rows) break :cursor;
            screen.cursorAbsolute(cursor_x, cursor_y);

            // A capture replay fills every row to the last column (it
            // is taken with -N), so it leaves the cursor in the bottom
            // right corner waiting to wrap. Moving the cursor does not
            // clear that by itself, and left set, the program's next
            // character would wrap onto the line below the one tmux has
            // the cursor on: everything it then draws relative to the
            // cursor lands a line low, and at the bottom of the screen
            // it scrolls. tmux reports a position, never a pending wrap.
            screen.cursor.pending_wrap = false;
        }

        // Set cursor shape on this screen
        if (data.cursor_shape.len > 0) {
            if (std.mem.eql(u8, data.cursor_shape, "block")) {
                screen.cursor.cursor_style = .block;
            } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                screen.cursor.cursor_style = .underline;
            } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                screen.cursor.cursor_style = .bar;
            }
        }
        // "default" or unknown: leave as-is
    }

    // The alternate screen's saved cursor is, despite its name, the
    // primary screen's: tmux records where the primary cursor was when
    // DECSET 1049 entered the alternate screen, and puts it back there
    // when 1049 leaves (screen_alternate_on/off in tmux's screen.c).
    // Only meaningful while the alternate screen is up: tmux never
    // clears it, so on the primary screen it is whatever an earlier
    // 1049 left behind, and MAX_INT if there was none.
    //
    // Ghostty keeps the same thing as the primary screen's saved cursor,
    // which 1049 restores on the way out. The cursor itself is left
    // where it was, which is where tmux saved it from.
    if (data.alternate_on) if (t.screens.get(.primary)) |primary| cursor: {
        const saved_x = std.math.cast(
            size.CellCountInt,
            data.alternate_saved_x,
        ) orelse break :cursor;
        const saved_y = std.math.cast(
            size.CellCountInt,
            data.alternate_saved_y,
        ) orelse break :cursor;

        // If our coordinates are outside our screen we ignore it.
        // tmux actually sends MAX_INT for when there isn't a set
        // cursor position, so this isn't theoretical.
        if (saved_x >= primary.pages.cols or
            saved_y >= primary.pages.rows) break :cursor;

        primary.cursorAbsolute(saved_x, saved_y);
        if (primary.saved_cursor) |*saved| {
            saved.x = saved_x;
            saved.y = saved_y;
        } else primary.saved_cursor = .{
            .x = saved_x,
            .y = saved_y,
            .style = .{},
            .protected = false,
            .pending_wrap = false,
            .origin = false,
            .charset = .{},
        };
    };

    // Set cursor visibility
    t.modes.set(.cursor_visible, data.cursor_flag);

    // Set cursor blinking
    t.modes.set(.cursor_blinking, data.cursor_blinking);

    // Terminal modes
    t.modes.set(.insert, data.insert_flag);
    t.modes.set(.wraparound, data.wrap_flag);
    t.modes.set(.keypad_keys, data.keypad_flag);
    t.modes.set(.cursor_keys, data.keypad_cursor_flag);
    t.modes.set(.origin, data.origin_flag);

    // Mouse modes
    t.modes.set(.mouse_event_any, data.mouse_all_flag);
    t.modes.set(.mouse_event_button, data.mouse_button_flag);
    t.modes.set(.mouse_event_normal, data.mouse_standard_flag);
    t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
    t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

    // Focus and bracketed paste
    t.modes.set(.focus_event, data.focus_flag);
    t.modes.set(.bracketed_paste, data.bracketed_paste);

    // Scroll region (tmux uses 0-based values)
    scroll: {
        const scroll_top = std.math.cast(
            size.CellCountInt,
            data.scroll_region_upper,
        ) orelse break :scroll;
        const scroll_bottom = std.math.cast(
            size.CellCountInt,
            data.scroll_region_lower,
        ) orelse break :scroll;

        // Ignore invalid regions. The terminal assumes the scroll
        // region is always within the screen bounds.
        if (scroll_top >= scroll_bottom or
            scroll_bottom >= t.rows) break :scroll;

        t.scrolling_region.top = scroll_top;
        t.scrolling_region.bottom = scroll_bottom;
    }

    // Tab stops - parse comma-separated list and set
    t.tabstops.reset(0); // Clear all tabstops first
    if (data.pane_tabs.len > 0) {
        var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
        while (tabs_it.next()) |tab_str| {
            const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
            const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
            if (col_cell >= t.cols) continue;
            t.tabstops.set(col_cell);
        }
    }
}

test "cloned ops own their payloads" {
    const alloc = testing.allocator;

    // Build the payloads in a buffer we scribble over afterwards, so a
    // clone that aliased its source is caught rather than merely lucky.
    var scratch: [32]u8 = undefined;
    @memcpy(scratch[0..5], "hello");
    @memcpy(scratch[8..13], "block");
    @memcpy(scratch[16..20], "8,16");

    var data: PaneStateData = std.mem.zeroes(PaneStateData);
    data.pane_id = 3;
    data.cursor_shape = scratch[8..13];
    data.pane_tabs = scratch[16..20];

    const bytes = try (Op{ .bytes = scratch[0..5] }).clone(alloc);
    defer bytes.deinit(alloc);
    const state = try (Op{ .pane_state = data }).clone(alloc);
    defer state.deinit(alloc);

    @memset(&scratch, 'x');

    try testing.expectEqualStrings("hello", bytes.bytes);
    try testing.expectEqualStrings("block", state.pane_state.cursor_shape);
    try testing.expectEqualStrings("8,16", state.pane_state.pane_tabs);
    try testing.expectEqual(3, state.pane_state.pane_id);
}

test "cloning a payload-free op copies it as-is" {
    const alloc = testing.allocator;
    const ops: []const Op = &.{
        .{ .switch_screen = .alternate },
        .scroll_into_history,
        .erase_and_home,
        .erase_all,
        .trim_trailing_blanks,
        .{ .resize = .{ .cols = 80, .rows = 24 } },
    };

    for (ops) |op| {
        const copy = try op.clone(alloc);
        defer copy.deinit(alloc);
        try testing.expectEqual(
            std.meta.activeTag(op),
            std.meta.activeTag(copy),
        );
    }
}

test "erase_all clears the scrollback as well as the display" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // More lines than rows, so some are in scrollback.
    for ("abcde") |c| {
        try t.print(c);
        t.carriageReturn();
        try t.linefeed();
    }
    t.modes.set(.bracketed_paste, true);

    try applyOp(alloc, &t, .erase_all);

    const text = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(text);
    try testing.expectEqualStrings("", text);
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);

    // Content only: modes are left alone.
    try testing.expect(t.modes.get(.bracketed_paste));
}

test "trim_trailing_blanks empties plain padding and keeps painted cells" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 8, .rows = 3 });
    defer t.deinit(alloc);

    // What `capture-pane -N -e` sends: a word padded with plain spaces,
    // a bar painted in a colour, and a word followed by reverse video.
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("ab      ");
    stream.nextSlice("\x1b[2;1H\x1b[44m        \x1b[49m");
    stream.nextSlice("\x1b[3;1Hc \x1b[7m  \x1b[27m    ");

    try applyOp(alloc, &t, .trim_trailing_blanks);

    const screen = t.screens.active;
    const cell = struct {
        fn at(s: anytype, x: u16, y: u16) @import("../page.zig").Cell {
            return s.pages.getCell(.{ .active = .{ .x = x, .y = y } }).?.cell.*;
        }
    }.at;

    // Plain padding is gone: empty cells, as a trimmed capture leaves.
    try testing.expectEqual(@as(u21, 'b'), cell(screen, 1, 0).codepoint());
    for (2..8) |x| try testing.expectEqual(@as(u21, 0), cell(screen, @intCast(x), 0).codepoint());

    // The painted bar is all still there.
    for (0..8) |x| try testing.expect(cell(screen, @intCast(x), 1).style_id != 0);

    // Reverse video blanks are kept, the plain ones after them are not,
    // and the plain space before them is inner, so it stays.
    try testing.expectEqual(@as(u21, ' '), cell(screen, 1, 2).codepoint());
    try testing.expect(cell(screen, 2, 2).style_id != 0);
    try testing.expect(cell(screen, 3, 2).style_id != 0);
    for (4..8) |x| try testing.expectEqual(@as(u21, 0), cell(screen, @intCast(x), 2).codepoint());
}

test "pane state puts the cursor where tmux has it, not waiting to wrap" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 4, .rows = 2 });
    defer t.deinit(alloc);

    // A replay that fills the screen leaves the cursor at the end of
    // the last row with a wrap pending.
    try applyOp(alloc, &t, .{ .replay = "abcd\r\nefgh" });
    try testing.expect(t.screens.active.cursor.pending_wrap);

    var data: PaneStateData = std.mem.zeroes(PaneStateData);
    data.cursor_x = 1;
    data.cursor_y = 0;
    data.cursor_shape = "";
    data.cursor_colour = "";
    data.pane_tabs = "";
    data.scroll_region_upper = 0;
    data.scroll_region_lower = 1;
    try applyOp(alloc, &t, .{ .pane_state = data });

    // The next character goes where tmux would put it.
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("X");
    const text = try t.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(text);
    try testing.expectEqualStrings("aXcd\nefgh", text);
}
