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
const PageList = @import("../PageList.zig");
const Cell = @import("../page.zig").Cell;
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

/// Which pane a pane trades places with.
///
/// Lives here for the same reason as `KillScope`.
pub const SwapTarget = enum {
    /// The pane before it in tmux's own pane order, as `swap-pane -U`
    /// (tmux's `{` binding) has it.
    previous,
    /// The pane after it, as `swap-pane -D` (`}`).
    next,
    /// The pane beside it on that side of the window's layout.
    left,
    right,
    up,
    down,
};

/// One step either way along an order tmux keeps: a window's panes for
/// `rotate-window`, the session's windows for `join-pane`.
///
/// Lives here for the same reason as `KillScope`.
pub const Adjacent = enum {
    previous,
    next,
};

/// How current a pane's display is with tmux, beyond what its content
/// shows. Displays that have room to say so should: a pane that is not
/// `live` can look complete and not be.
///
/// Sync with: ghostty_action_tmux_pane_status_e
pub const PaneStatus = enum(c_int) {
    /// Up to date: everything tmux has for the pane is here.
    live,

    /// The screen is shown and the history above it is still being
    /// read, so scrolling up finds less than tmux has. It arrives on its
    /// own; nothing is wrong.
    loading_history,

    /// tmux paused the pane because we fell too far behind it
    /// (`tmux-pause-after`), and it is being read again. What is on
    /// screen may be stale until it is, and output from while it was
    /// paused is gone for good.
    catching_up,
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

    /// A string sequence (OSC, DCS or APC) that the pane's program
    /// wrapped in tmux's passthrough escape, unwrapped. See
    /// `passthrough.zig`.
    ///
    /// For the same stream as `.bytes`, which it may be split across
    /// like any other sequence. tmux never sees it take effect, so it
    /// must not move the cursor of a terminal that mirrors tmux's grid:
    /// a kitty graphics placement would. The viewer's own terminal skips
    /// it, having no use for notifications or images.
    passthrough: []const u8,

    /// Make the given screen active, without any of the side effects that
    /// the DECSET alternate-screen modes carry.
    switch_screen: ScreenSet.Key,

    /// Push the whole active area into scrollback and home the cursor. This
    /// is the tail of a history replay, and uses the applying terminal's own
    /// row count.
    scroll_into_history,

    /// History older than any the terminal holds, to go above it. See
    /// `OlderHistory`.
    older_history: OlderHistory,

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

    /// The pane's title, tmux's `#{pane_title}`.
    ///
    /// Usually what the pane's program last set with OSC 0 or 2, which
    /// also arrives as bytes. This covers what the bytes cannot: the
    /// title a pane already had when we attached, and one set by tmux
    /// itself (`select-pane -T`, or the host name tmux starts a pane
    /// with). A consumer should treat it as an OSC 2 from the program.
    title: []const u8,

    /// The working directory of the pane's program, tmux's
    /// `#{pane_current_path}`, on the tmux server's host.
    ///
    /// tmux reads this from the process itself, so it is known without
    /// any shell integration. The host is part of it because the path
    /// is only meaningful there: a consumer should treat it as an OSC 7
    /// report from that host, and so ignore it unless the host is ours.
    pwd: Pwd,

    /// The pane's display is now this current with tmux. Not terminal
    /// state: `applyOp` ignores it, and a consumer with a GUI shows it.
    pane_status: PaneStatus,

    /// The pane's whole history, as far as `tmux-history-limit` goes, is
    /// in: the read a display asked for with `Viewer.Input.read_history`
    /// has been applied. Not terminal state; `applyOp` ignores it. A
    /// display holding back something that needs all of the scrollback
    /// (select all, writing it to a file) does it now.
    history_complete,

    pub const Pwd = struct {
        host: []const u8,
        path: []const u8,
    };

    /// A capture of a run of tmux's history, read because the display
    /// was scrolled to the top of what it holds. See `prependHistory`.
    ///
    /// tmux numbers history lines back from the screen: 1 is the line
    /// just above it. A terminal mirroring a pane holds the newest lines
    /// of that history, one row each (a capture of tmux's grid at the
    /// pane's own width, without `-J`, is a row per line), so with `n`
    /// rows of scrollback it holds lines 1 through `n`. That stays true
    /// as output scrolls more lines into both, which is what lets the
    /// capture be placed: applied in order with the pane's output, it is
    /// a snapshot of tmux's history at the same point in the stream.
    ///
    /// Only the lines older than any the terminal has are added, above
    /// its scrollback, without touching what is there: the viewport,
    /// a selection and search results all stay on the content they were
    /// on. A capture that does not reach down to the terminal's oldest
    /// line adds nothing: it was asked for before the terminal's history
    /// was replaced, and the display asks again. One whose line there is
    /// not the terminal's adds nothing either, and fails with
    /// `error.HistoryDrifted`: the two histories no longer agree line for
    /// line, and only reading the pane again from scratch fixes that.
    pub const OlderHistory = struct {
        /// The capture, decoded: one line of tmux's history per row,
        /// oldest first.
        bytes: []const u8,

        /// How far back from the screen the capture's last line is.
        /// Always at least 1.
        newest: usize,

        /// Which read from scratch the read was measured against, for
        /// telling the viewer about it if it does not line up. See
        /// `Viewer.Input.history_drifted`.
        read: u32 = 0,
    };

    /// Copy an op so it can outlive the sink call that delivered it.
    ///
    /// A sink that hands ops to another thread has to do this: the
    /// payloads point into the viewer's notification and arena memory.
    pub fn clone(self: Op, alloc: Allocator) Allocator.Error!Op {
        return switch (self) {
            .bytes => |b| .{ .bytes = try alloc.dupe(u8, b) },
            .replay => |b| .{ .replay = try alloc.dupe(u8, b) },
            .title => |t| .{ .title = try alloc.dupe(u8, t) },
            .pwd => |p| pwd: {
                const host = try alloc.dupe(u8, p.host);
                errdefer alloc.free(host);
                break :pwd .{ .pwd = .{
                    .host = host,
                    .path = try alloc.dupe(u8, p.path),
                } };
            },
            .passthrough => |b| .{ .passthrough = try alloc.dupe(u8, b) },
            .older_history => |v| .{ .older_history = .{
                .bytes = try alloc.dupe(u8, v.bytes),
                .newest = v.newest,
            } },

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
            .pane_status,
            .history_complete,
            => self,
        };
    }

    /// Free an op produced by `clone`. Never call this on an op that came
    /// straight from the viewer; those payloads are not ours.
    pub fn deinit(self: Op, alloc: Allocator) void {
        switch (self) {
            .bytes, .replay, .passthrough => |b| alloc.free(b),
            .older_history => |v| alloc.free(v.bytes),
            .title => |t| alloc.free(t),
            .pwd => |p| {
                alloc.free(p.host);
                alloc.free(p.path);
            },
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
/// `.bytes` and `.passthrough` are not handled here: the caller owns the
/// stream, because parser state has to persist across calls.
pub fn applyOp(
    alloc: Allocator,
    t: *Terminal,
    op: Op,
) !void {
    switch (op) {
        .bytes, .passthrough => unreachable,

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

        .older_history => |v| try prependHistory(alloc, t, v),

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

        .title => |title| try t.setTitle(title),

        // Only the path: the host is for whoever decides whether the path
        // means anything here, and a terminal keeps no host.
        .pwd => |p| try t.setPwd(p.path),

        .resize => |v| try t.resize(alloc, .{
            .cols = v.cols,
            .rows = v.rows,
        }),

        // For whoever displays the terminal, not for the terminal.
        .pane_status, .history_complete => {},
    }
}

/// See `Op.OlderHistory`. Always the primary screen, whichever is
/// active: history is only ever the primary's.
fn prependHistory(
    alloc: Allocator,
    t: *Terminal,
    v: Op.OlderHistory,
) !void {
    const screen = t.screens.get(.primary) orelse return;
    const pages = &screen.pages;
    const held = pages.total_rows - pages.rows;

    // The capture has to reach at least the line just above our oldest,
    // or there would be lines missing between the two.
    if (v.newest == 0 or v.newest > held + 1) {
        log.info(
            "older history stops short of ours newest={} held={}",
            .{ v.newest, held },
        );
        return;
    }

    // Laid out as a history replay always is, at our width, but on a
    // terminal of its own to copy rows from.
    var scratch: Terminal = try .init(t.io(), alloc, .{
        .cols = t.cols,
        .rows = t.rows,
        .max_scrollback_bytes = null,
    });
    defer scratch.deinit(alloc);
    scratch.modes.set(.grapheme_cluster, t.modes.get(.grapheme_cluster));
    {
        var stream = scratch.vtStream();
        defer stream.deinit();
        stream.nextSlice(v.bytes);
    }
    scratch.carriageReturn();
    for (0..scratch.rows) |_| try scratch.index();

    // The capture's rows, oldest first, and how far back the oldest is.
    const source = &scratch.screens.active.pages;
    const lines = source.total_rows - source.rows;
    if (lines == 0) return;
    const oldest = v.newest + lines - 1;
    if (oldest <= held) return;
    const keep = oldest - held;

    // Where the capture overlaps what we have, its line there has to be
    // ours. One that is not means our scrollback and tmux's history have
    // drifted apart (each clears and reflows by its own rules), and the
    // capture would go in at the wrong place: better none than that.
    if (keep < lines) {
        const theirs = source.pin(.{ .screen = .{ .y = @intCast(keep) } }).?;
        const ours = pages.pin(.{ .screen = .{} }).?;
        if (!sameText(theirs.cells(.all), ours.cells(.all))) {
            log.warn("older history does not line up with ours, dropping it", .{});
            return error.HistoryDrifted;
        }
    }

    // A viewport at the top stays on what it shows rather than jumping
    // to the new top. Any other viewport is a pin, or the active area,
    // neither of which a prepend moves.
    const top: ?PageList.Pin = if (pages.viewport == .top)
        pages.getTopLeft(.screen)
    else
        null;
    defer if (top) |p| pages.scroll(.{ .pin = p });

    // The rows go on top a page at a time, so the newest of them first.
    // History is the start of the screen, so rows `0..keep` are the
    // start of the capture's pages.
    var node = source.pages.first.?;
    var start: usize = 0;
    while (start + node.rows() < keep) {
        start += node.rows();
        node = node.next.?;
    }
    var len = keep - start;
    while (true) {
        const page = node.page();
        var allocation = try pages.allocatePage(page.exactRowCapacity(0, len));
        defer allocation.deinit();
        const dst = allocation.page();
        dst.size.rows = @intCast(len);
        try dst.cloneFrom(page, 0, len);

        // Past our scrollback limit: we have as much as we may keep.
        allocation.finalize(.prepend, .{}) catch |err| {
            log.info("scrollback full, older history dropped err={}", .{err});
            return;
        };

        node = node.prev orelse return;
        len = node.rows();
    }
}

/// Whether two rows hold the same text, which is all a capture and live
/// output can be relied on to agree about: blanks, unwritten cells and
/// cells with only a background are all a space to a capture.
fn sameText(a: []const Cell, b: []const Cell) bool {
    for (0..@max(a.len, b.len)) |x| {
        if (cellText(a, x) != cellText(b, x)) return false;
    }
    return true;
}

fn cellText(cells: []const Cell, x: usize) u21 {
    if (x >= cells.len) return ' ';
    const cell = cells[x];
    return switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => switch (cell.codepoint()) {
            0 => ' ',
            else => |cp| cp,
        },
        else => ' ',
    };
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

    // modifyOtherKeys. Our keys reach the program as the bytes we encode
    // them to (`send-keys -H`), so the encoding has to be the one it
    // asked for. tmux's level 1 is ours off: we only implement 2. An
    // empty value is a tmux before 3.5, which cannot tell us, and the
    // flag is left as live output set it.
    //
    // The kitty keyboard flags have no equivalent: tmux 3.6 neither
    // implements the protocol nor keeps the flags a program pushed, so
    // a program that set them before we attached keeps getting legacy
    // keys from us. Programs that ask first (`CSI ? u`) never set them
    // under tmux, since tmux leaves that query unanswered.
    if (std.mem.eql(u8, data.pane_key_mode, "Ext 2")) {
        t.flags.modify_other_keys_2 = true;
    } else if (data.pane_key_mode.len > 0) {
        t.flags.modify_other_keys_2 = false;
    }

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
    const title = try (Op{ .title = scratch[0..5] }).clone(alloc);
    defer title.deinit(alloc);
    const pwd = try (Op{ .pwd = .{
        .host = scratch[8..13],
        .path = scratch[16..20],
    } }).clone(alloc);
    defer pwd.deinit(alloc);

    @memset(&scratch, 'x');

    try testing.expectEqualStrings("hello", title.title);
    try testing.expectEqualStrings("block", pwd.pwd.host);
    try testing.expectEqualStrings("8,16", pwd.pwd.path);
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
        .{ .pane_status = .catching_up },
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

test "pane state restores modifyOtherKeys as tmux reports it" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var data: PaneStateData = std.mem.zeroes(PaneStateData);
    data.cursor_shape = "";
    data.cursor_colour = "";
    data.pane_tabs = "";

    data.pane_key_mode = "Ext 2";
    try applyPaneState(&t, data);
    try testing.expect(t.flags.modify_other_keys_2);

    // A tmux too old to say leaves what we have alone.
    data.pane_key_mode = "";
    try applyPaneState(&t, data);
    try testing.expect(t.flags.modify_other_keys_2);

    // Level 1 is not one we implement.
    data.pane_key_mode = "Ext 1";
    try applyPaneState(&t, data);
    try testing.expect(!t.flags.modify_other_keys_2);

    t.flags.modify_other_keys_2 = true;
    data.pane_key_mode = "VT10x";
    try applyPaneState(&t, data);
    try testing.expect(!t.flags.modify_other_keys_2);
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

/// A terminal whose scrollback holds `history` lines, one per row, with
/// `screen` on display. Lines are separated by "\r\n", as a capture's are.
fn testHistoryTerminal(
    alloc: Allocator,
    history: []const u8,
    screen: []const u8,
) !Terminal {
    var t: Terminal = try .init(testing.io, alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback_bytes = null,
    });
    errdefer t.deinit(alloc);
    try applyOp(alloc, &t, .{ .replay = history });
    try applyOp(alloc, &t, .scroll_into_history);
    try applyOp(alloc, &t, .{ .replay = screen });
    return t;
}

fn expectHistory(alloc: Allocator, t: *Terminal, expected: []const u8) !void {
    const text = try t.screens.get(.primary).?.dumpStringAlloc(
        alloc,
        .{ .history = .{} },
    );
    defer alloc.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "older history goes in above what is held, past the line they share" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x\r\ny\r\nz");
    defer t.deinit(alloc);

    // Three lines held, so tmux's lines 3 back to 5 are "c", "b" and
    // "a". The capture ends on the oldest one we hold.
    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "a\r\nb\r\nc",
        .newest = 3,
    } });
    try expectHistory(alloc, &t, "a\nb\nc\nd\ne");

    // The screen is untouched.
    const screen = try t.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(screen);
    try testing.expectEqualStrings("x\ny\nz", screen);
}

test "older history whose overlap is not ours adds nothing, and says so" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x");
    defer t.deinit(alloc);

    // Line 3 back is "c" here, and tmux says it is "q": the two have
    // drifted apart, and "a" and "b" would go in at the wrong place.
    try testing.expectError(error.HistoryDrifted, applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "a\r\nb\r\nq",
        .newest = 3,
    } }));
    try expectHistory(alloc, &t, "c\nd\ne");
}

test "older history that stops short of ours adds nothing" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x");
    defer t.deinit(alloc);

    // Lines 5 back to 7: line 4 would be missing between the two.
    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "a\r\nb\r\nc",
        .newest = 5,
    } });
    try expectHistory(alloc, &t, "c\nd\ne");
}

test "older history that is all held already adds nothing" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x");
    defer t.deinit(alloc);

    // Output scrolled more lines into both before tmux ran the capture,
    // so all of it is ours by the time it lands.
    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "c\r\nd",
        .newest = 2,
    } });
    try expectHistory(alloc, &t, "c\nd\ne");
}

test "older history right above ours needs no overlap, and keeps blank lines" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x");
    defer t.deinit(alloc);

    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "a\r\n\r\nb",
        .newest = 4,
    } });
    try expectHistory(alloc, &t, "a\n\nb\nc\nd\ne");
}

test "older history leaves the viewport and pins on their content" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "c\r\nd\r\ne", "x");
    defer t.deinit(alloc);
    const pages = &t.screens.active.pages;

    // Scrolled all the way up, and something (a selection, a search
    // result) pinned to "d".
    pages.scroll(.top);
    const d = try pages.trackPin(pages.pin(.{ .history = .{ .y = 1 } }).?);
    defer pages.untrackPin(d);

    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = "a\r\nb\r\nc",
        .newest = 3,
    } });

    // Still showing "c" at the top, with the new lines above it to
    // scroll up to.
    const top = pages.getTopLeft(.viewport);
    try testing.expectEqual(@as(u21, 'c'), top.rowAndCell().cell.codepoint());
    try testing.expect(pages.viewport != .top);
    try testing.expectEqual(@as(u21, 'd'), d.rowAndCell().cell.codepoint());
    try testing.expectEqual(
        @as(u32, 3),
        pages.pointFromPin(.history, d.*).?.history.y,
    );
}

test "older history spanning several pages goes in whole and in order" {
    const alloc = testing.allocator;
    var t = try testHistoryTerminal(alloc, "held", "x");
    defer t.deinit(alloc);

    // Far more lines than a page holds, ending on the one we hold.
    var capture: std.Io.Writer.Allocating = .init(alloc);
    defer capture.deinit();
    const count = 5000;
    for (0..count) |i| try capture.writer.print("{d}\r\n", .{i});
    try capture.writer.writeAll("held");

    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = capture.written(),
        .newest = 1,
    } });

    const pages = &t.screens.active.pages;
    try testing.expect(pages.totalPages() > 2);
    try testing.expectEqual(count + 1, pages.total_rows - pages.rows);
    var buf: [16]u8 = undefined;
    for ([_]usize{ 0, 1, 1234, count - 1 }) |i| {
        const pin = pages.pin(.{ .history = .{ .y = @intCast(i) } }).?;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{i});
        const cells = pin.cells(.all);
        for (text, 0..) |c, x| try testing.expectEqual(@as(u21, c), cells[x].codepoint());
    }
    const last = pages.pin(.{ .history = .{ .y = count } }).?;
    try testing.expectEqual(@as(u21, 'h'), last.rowAndCell().cell.codepoint());
}

test "older history stops at the scrollback limit" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback_bytes = 10_000,
    });
    defer t.deinit(alloc);
    try applyOp(alloc, &t, .{ .replay = "held" });
    try applyOp(alloc, &t, .scroll_into_history);

    var capture: std.Io.Writer.Allocating = .init(alloc);
    defer capture.deinit();
    const count = 5000;
    for (0..count) |i| try capture.writer.print("{d}\r\n", .{i});
    try capture.writer.writeAll("held");
    try applyOp(alloc, &t, .{ .older_history = .{
        .bytes = capture.written(),
        .newest = 1,
    } });

    // As much as fits goes in, newest first, and nothing is pushed out
    // to make room: what was held is still the newest history, and
    // right above it is the newest of what was read.
    const pages = &t.screens.active.pages;
    const held = pages.total_rows - pages.rows;
    try testing.expect(held < count + 1);
    const last = pages.pin(.{ .history = .{ .y = @intCast(held - 1) } }).?;
    try testing.expectEqual(@as(u21, 'h'), last.rowAndCell().cell.codepoint());
    if (held > 1) {
        const above = pages.pin(.{ .history = .{ .y = @intCast(held - 2) } }).?;
        const cells = above.cells(.all);
        for ("4999", 0..) |c, x| try testing.expectEqual(@as(u21, c), cells[x].codepoint());
    }
}
