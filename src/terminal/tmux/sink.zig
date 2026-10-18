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

pub const Op = union(enum) {
    /// Raw VT bytes: `%output` data, or capture-pane replay content.
    ///
    /// These must go through a stream whose parser state persists across
    /// ops, because a sequence can be split across notifications.
    bytes: []const u8,

    /// Make the given screen active, without any of the side effects that
    /// the DECSET alternate-screen modes carry.
    switch_screen: ScreenSet.Key,

    /// Push the whole active area into scrollback and home the cursor. This
    /// is the tail of a history replay, and uses the applying terminal's own
    /// row count.
    scroll_into_history,

    /// Clear the display and home the cursor, ahead of a visible replay.
    erase_and_home,

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
            .resize,
            => self,
        };
    }

    /// Free an op produced by `clone`. Never call this on an op that came
    /// straight from the viewer; those payloads are not ours.
    pub fn deinit(self: Op, alloc: Allocator) void {
        switch (self) {
            .bytes => |b| alloc.free(b),
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

        .pane_state => |data| try applyPaneState(t, data),

        .resize => |v| try t.resize(alloc, .{
            .cols = v.cols,
            .rows = v.rows,
        }),
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
