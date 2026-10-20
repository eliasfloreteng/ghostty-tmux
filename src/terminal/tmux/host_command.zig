//! The command line that started a tmux control mode session, read back
//! from the terminal that ran it.
//!
//! When the connection to a session drops (ssh losing the network, say)
//! the session is very likely still running on the server, and the way
//! back to it is to run whatever started it again: `tmux -CC attach`, or
//! `ssh host -t tmux -CC new -A -s main`. Control mode does not tell us
//! what that was, but the host terminal saw it typed. Shell integration
//! marks which cells of a prompt are the user's input (OSC 133), so the
//! input of the last prompt above the cursor, at the moment control mode
//! starts, is the command that started it.
//!
//! Without shell integration there are no marks and nothing is read:
//! telling a prompt from the command typed after it would be a guess,
//! and running a guess in someone's shell is not something to offer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Screen = @import("../Screen.zig");
const Selection = @import("../Selection.zig");
const Terminal = @import("../Terminal.zig");

/// The command line of the last prompt above the cursor, if it is one
/// that running again would reattach. Owned by the caller.
///
/// Null when there is no prompt to read (no shell integration), when the
/// command spans lines (a continuation prompt, which cannot be replayed
/// as one line), or when it does not run tmux in control mode itself.
/// The last is the common case of `ssh host` followed by `tmux -CC`
/// typed into the remote shell: the host only ever saw `ssh host`, and
/// running that again would not reattach anything.
pub fn read(alloc: Allocator, screen: *Screen) Allocator.Error!?[]const u8 {
    var it = screen.cursor.page_pin.promptIterator(.left_up, null);
    const prompt = it.next() orelse return null;
    const input = screen.pages.highlightSemanticContent(
        prompt,
        .input,
    ) orelse return null;

    const text = try screen.selectionString(alloc, .{
        .sel = Selection.init(input.start, input.end, false),
        .trim = true,
    });
    defer alloc.free(text);

    const command = std.mem.trim(u8, text, " \t");
    if (!reattaches(command)) return null;
    return try alloc.dupe(u8, command);
}

/// Whether running `command` again could plausibly reattach: one line,
/// nothing but printable text, and starting tmux in control mode.
fn reattaches(command: []const u8) bool {
    if (command.len == 0) return false;
    for (command) |c| if (c < 0x20 or c == 0x7F) return false;
    return std.mem.indexOf(u8, command, "-CC") != null;
}

/// Feed `input` to a fresh terminal and read the host command from it.
fn testRead(input: []const u8) !?[]const u8 {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 40, .rows = 6 });
    defer t.deinit(alloc);
    {
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(input);
    }
    return read(alloc, t.screens.active);
}

test "the command typed at the last prompt is read back" {
    const command = (try testRead(
        "\x1b]133;A\x07% \x1b]133;B\x07ls\r\n\x1b]133;C\x07file\r\n" ++
            "\x1b]133;D;0\x07" ++
            "\x1b]133;A\x07% \x1b]133;B\x07ssh host -t tmux -CC attach\r\n" ++
            "\x1b]133;C\x07",
    )).?;
    defer testing.allocator.free(command);
    try testing.expectEqualStrings("ssh host -t tmux -CC attach", command);
}

test "a command that wrapped is read back whole" {
    const command = (try testRead(
        "\x1b]133;A\x07% \x1b]133;B\x07" ++
            "ssh some-long-host-name.example.com -t 'tmux -CC new -A -s main'" ++
            "\r\n\x1b]133;C\x07",
    )).?;
    defer testing.allocator.free(command);
    try testing.expectEqualStrings(
        "ssh some-long-host-name.example.com -t 'tmux -CC new -A -s main'",
        command,
    );
}

test "nothing is read without shell integration" {
    try testing.expectEqual(null, try testRead("% tmux -CC attach\r\n"));
}

test "a command that does not start control mode is not read" {
    // `ssh host`, with `tmux -CC` then typed into a shell the host
    // terminal has no marks for.
    try testing.expectEqual(null, try testRead(
        "\x1b]133;A\x07% \x1b]133;B\x07ssh host\r\n\x1b]133;C\x07" ++
            "remote$ tmux -CC\r\n",
    ));
}
