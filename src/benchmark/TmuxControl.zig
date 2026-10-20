//! This benchmark tests the throughput of a tmux control mode session:
//! from the bytes tmux writes to a control client to the state of the
//! terminal that displays a pane.
//!
//! The data is what tmux sends: `%output` lines, with tmux's escaping,
//! for one pane (`%0`). Each byte goes through the control mode parser,
//! then the viewer, which keeps its own copy of the pane, then to a
//! second terminal standing in for the surface that shows it. That is
//! the work the host terminal's IO thread does for a pane, less the
//! router's copy between the two.
const TmuxControl = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const tmux = terminalpkg.tmux;

/// tmux control mode is only built where oniguruma is; elsewhere this
/// benchmark refuses to run.
const enabled = terminalpkg.options.tmux_control_mode;

const log = std.log.scoped(.@"tmux-control-bench");

opts: Options,
alloc: Allocator,
state: if (enabled) ?*State else void = if (enabled) null else {},

/// The file, opened in the setup function.
data_f: ?std.Io.File = null,

pub const Options = struct {
    /// The size of the pane.
    @"terminal-rows": u16 = 44,
    @"terminal-cols": u16 = 160,

    /// Pre-generated control mode data: `%output %0 ...` lines. If this
    /// is "-" then we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop).
    data: ?[]const u8 = null,
};

/// Everything a run builds up, made fresh in setup so every run starts
/// from an attached session with an empty pane.
const State = struct {
    parser: tmux.ControlParser,
    viewer: tmux.Viewer,
    surface: Terminal,
    stream: terminalpkg.TerminalStream,

    fn sink(self: *State) tmux.Sink {
        return .{ .ctx = self, .vtable = &.{
            .ops = applyOps,
            .close = close,
        } };
    }

    fn applyOps(ctx: *anyopaque, ops: []const tmux.Op) void {
        const self: *State = @ptrCast(@alignCast(ctx));
        for (ops) |op| switch (op) {
            // As the surface does, less putting its cursor back after
            // a passthrough, which this data has none of.
            .bytes, .passthrough => |b| self.stream.nextSlice(b),
            else => tmux.sink.applyOp(
                self.surface.gpa(),
                &self.surface,
                op,
            ) catch |err| log.warn("op failed err={}", .{err}),
        };
    }

    fn close(_: *anyopaque) void {}
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TmuxControl {
    const ptr = try alloc.create(TmuxControl);
    ptr.* = .{ .opts = opts, .alloc = alloc };
    return ptr;
}

pub fn destroy(self: *TmuxControl, alloc: Allocator) void {
    if (comptime enabled) assert(self.state == null);
    alloc.destroy(self);
}

pub fn benchmark(self: *TmuxControl) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TmuxControl = @ptrCast(@alignCast(ptr));
    if (comptime !enabled) {
        log.warn("tmux control mode is not in this build", .{});
        return error.BenchmarkFailed;
    }
    self.attach() catch |err| {
        log.warn("error attaching err={}", .{err});
        return error.BenchmarkFailed;
    };

    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Bring a viewer up to an attached session with one pane, the way tmux
/// answers an attach, and point its pane at our surface terminal.
fn attach(self: *TmuxControl) !void {
    const alloc = self.alloc;
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);

    state.parser = .{ .buffer = .init(alloc) };
    errdefer state.parser.deinit();
    state.viewer = try .init(global.io(), alloc, .{});
    errdefer state.viewer.deinit();
    state.surface = try .init(global.io(), alloc, .{
        .rows = self.opts.@"terminal-rows",
        .cols = self.opts.@"terminal-cols",
        .default_modes = .{ .grapheme_cluster = true },
    });
    errdefer state.surface.deinit(alloc);
    state.stream = state.surface.vtStream();

    var layout_buf: [128]u8 = undefined;
    const layout = try std.fmt.bufPrint(&layout_buf, "{d}x{d},0,0,0", .{
        self.opts.@"terminal-cols",
        self.opts.@"terminal-rows",
    });
    var line_buf: [512]u8 = undefined;
    const windows = try std.fmt.bufPrint(&line_buf, "$1 @0 1 {d} {d} {x:0>4},{s} 0 {x:0>4},{s} 0 0 0 0 %0 bench", .{
        self.opts.@"terminal-cols",
        self.opts.@"terminal-rows",
        checksum(layout),
        layout,
        checksum(layout),
        layout,
    });

    const replies = [_]tmux.ControlNotification{
        .{ .block_end = "" },
        .{ .session_changed = .{ .id = 1, .name = "bench" } },
        .{ .block_end = "3.6 0 bench" },
        .{ .block_end = windows },
        // The pane's history, saved grid and grid on display, the
        // subscriptions, then the pane state.
        .{ .block_end = "" },
        .{ .block_err = "no alternate screen" },
        .{ .block_end = "" },
        .{ .block_end = "" },
        .{ .block_end = "" },
    };
    for (replies, 0..) |n, i| {
        _ = state.viewer.next(.{ .tmux = n });
        // Attach once the window list is in, as the GUI does.
        if (i == 3) try state.viewer.attachPane(0, state.sink());
    }

    // Every command the attach sent has its reply, or the data below
    // would be measured against a session still starting up.
    if (!state.viewer.command_queue.empty()) return error.AttachIncomplete;

    self.state = state;
}

/// tmux's layout checksum.
fn checksum(layout: []const u8) u16 {
    var csum: u16 = 0;
    for (layout) |c| {
        csum = (csum >> 1) +% ((csum & 1) << 15);
        csum +%= c;
    }
    return csum;
}

fn teardown(ptr: *anyopaque) void {
    const self: *TmuxControl = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close(global.io());
        self.data_f = null;
    }
    if (comptime !enabled) return;
    if (self.state) |state| {
        state.viewer.deinit();
        state.parser.deinit();
        state.stream.deinit();
        state.surface.deinit(self.alloc);
        self.alloc.destroy(state);
        self.state = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TmuxControl = @ptrCast(@alignCast(ptr));
    if (comptime !enabled) return;
    const f = self.data_f orelse return;
    const state = self.state orelse return;

    var f_reader = f.reader(global.io(), &.{});
    const r = &f_reader.interface;

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        for (buf[0..n]) |byte| {
            const notification = state.parser.put(byte) catch
                return error.BenchmarkFailed;
            if (notification) |v| _ = state.viewer.next(.{ .tmux = v });
        }
    }
}

test TmuxControl {
    if (comptime !enabled) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *TmuxControl = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
