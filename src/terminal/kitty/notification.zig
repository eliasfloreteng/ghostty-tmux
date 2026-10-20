//! Putting together a desktop notification from kitty's protocol (OSC 99).
//! Specification: https://sw.kovidgoyal.net/kitty/desktop-notifications/
//!
//! A program can send a notification's title and body in pieces under an
//! identifier, `d=0` on all but the last, and the last (`d=1`, the default)
//! shows it. This keeps the one being put together.
//!
//! Only what a desktop notification here can show is kept: the title and
//! the body. Icons, buttons, sounds, urgency, close and liveness requests
//! and queries are ignored, and so is `o` (when to notify): whether to
//! notify a focused surface is the app's call, as it is for OSC 9 and
//! OSC 777. Nothing is ever reported back to the program.

const std = @import("std");
const testing = std.testing;

const osc = @import("../osc.zig");
const parser = @import("../osc/parsers/kitty_desktop_notification.zig");

const OSC = osc.Command.KittyDesktopNotification;

pub const Notification = struct {
    pending: bool = false,

    /// The identifier the pending notification was started under; empty
    /// for none.
    id: [max_id_len]u8 = undefined,
    id_len: usize = 0,

    /// More than a desktop notification shows, so that whoever shows it
    /// is the one to cut it short, on a codepoint boundary.
    title: [512]u8 = undefined,
    title_len: usize = 0,
    body: [2048]u8 = undefined,
    body_len: usize = 0,

    /// Longer identifiers are not kept apart from each other.
    const max_id_len = 64;

    pub const Show = struct {
        title: []const u8,
        body: []const u8,
    };

    /// Take one OSC 99. Returns the notification to show if this one
    /// completes it, valid until the next call.
    pub fn next(self: *Notification, cmd: OSC) ?Show {
        const kind = cmd.readOption(.p);
        switch (kind) {
            .title, .body => {},

            // Nothing here to show. A query in particular must not end
            // a notification being put together.
            .query, .close, .alive, .buttons, .icon, .unknown => return null,
        }

        // A notification that never got its `d=1` is given up on when
        // another one starts.
        const id = cmd.readOption(.i) orelse "";
        const id_trunc = id[0..@min(id.len, max_id_len)];
        if (self.pending and
            !std.mem.eql(u8, self.id[0..self.id_len], id_trunc))
        {
            self.pending = false;
        }
        if (!self.pending) {
            self.pending = true;
            @memcpy(self.id[0..id_trunc.len], id_trunc);
            self.id_len = id_trunc.len;
            self.title_len = 0;
            self.body_len = 0;
        }

        var decoded: [parser.MAX_ENCODED_PAYLOAD_BYTES]u8 = undefined;
        const payload = if (cmd.readOption(.e)) payload: {
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(cmd.payload) catch break :payload "";
            if (n > decoded.len) break :payload "";
            dec.decode(decoded[0..n], cmd.payload) catch break :payload "";
            break :payload decoded[0..n];
        } else cmd.payload;

        switch (kind) {
            .title => append(&self.title, &self.title_len, payload),
            .body => append(&self.body, &self.body_len, payload),
            else => unreachable,
        }

        if (!cmd.readOption(.d)) return null;
        self.pending = false;

        // Programs often end a notification with an empty chunk of its
        // own, after one that already showed it. That is not a second
        // notification.
        if (self.title_len == 0 and self.body_len == 0) return null;
        return .{
            .title = self.title[0..self.title_len],
            .body = self.body[0..self.body_len],
        };
    }

    fn append(buf: []u8, len: *usize, data: []const u8) void {
        const n = @min(buf.len - len.*, data.len);
        @memcpy(buf[len.* .. len.* + n], data[0..n]);
        len.* += n;
    }
};

fn testOsc(comptime str: []const u8) OSC {
    const semi = comptime std.mem.indexOfScalar(u8, str, ';').?;
    return .{
        .metadata = str[0..semi],
        .payload = str[semi + 1 ..],
        .terminator = .st,
    };
}

test "a single OSC 99 is a notification with a title" {
    var n: Notification = .{};
    const show = n.next(testOsc(";Hello")).?;
    try testing.expectEqualStrings("Hello", show.title);
    try testing.expectEqualStrings("", show.body);
}

test "title and body put together the way Claude Code sends them" {
    var n: Notification = .{};
    try testing.expect(n.next(testOsc("i=42:d=0:p=title;Claude Code")) == null);
    const show = n.next(testOsc("i=42:p=body;Waiting for input")).?;
    try testing.expectEqualStrings("Claude Code", show.title);
    try testing.expectEqualStrings("Waiting for input", show.body);

    // The closing chunk carries nothing new and shows nothing.
    try testing.expect(n.next(testOsc("i=42:d=1:a=focus;")) == null);
}

test "chunks of one kind are joined" {
    var n: Notification = .{};
    try testing.expect(n.next(testOsc("i=1:d=0;Hel")) == null);
    const show = n.next(testOsc("i=1;lo")).?;
    try testing.expectEqualStrings("Hello", show.title);
}

test "a base64 payload is decoded" {
    var n: Notification = .{};
    const show = n.next(testOsc("e=1:p=body;aGkgdGhlcmU=")).?;
    try testing.expectEqualStrings("hi there", show.body);
}

test "a new identifier gives up on an unfinished notification" {
    var n: Notification = .{};
    try testing.expect(n.next(testOsc("i=a:d=0;stale")) == null);
    const show = n.next(testOsc("i=b;fresh")).?;
    try testing.expectEqualStrings("fresh", show.title);
}

test "queries and other payloads leave a notification alone" {
    var n: Notification = .{};
    try testing.expect(n.next(testOsc("i=a:d=0;Title")) == null);
    try testing.expect(n.next(testOsc("i=b:p=?;")) == null);
    try testing.expect(n.next(testOsc("i=a:d=0:p=icon;AAAA")) == null);
    const show = n.next(testOsc("i=a:p=body;Body")).?;
    try testing.expectEqualStrings("Title", show.title);
    try testing.expectEqualStrings("Body", show.body);
}
