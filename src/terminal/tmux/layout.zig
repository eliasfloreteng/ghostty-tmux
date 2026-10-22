const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// A tmux layout.
///
/// This is a tree structure so by definition it pretty much needs to be
/// allocated. We leave allocation up to the user of this struct, but
/// a general recommendation is to use an arena allocator for simplicity
/// in freeing the entire layout at once.
pub const Layout = struct {
    /// Width, height of the node
    width: usize,
    height: usize,

    /// X and Y offset from the top-left corner of the window.
    x: usize,
    y: usize,

    /// The content of this node, either a pane (leaf) or more nodes
    /// (split) horizontally or vertically.
    content: Content,

    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };

    pub const ParseError = Allocator.Error || error{SyntaxError};

    /// Parse a layout string that includes a 4-character checksum prefix.
    ///
    /// The expected format is: `XXXX,layout_string` where XXXX is the
    /// 4-character hexadecimal checksum and the layout string follows
    /// after the comma. For example: `f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}`.
    ///
    /// Returns `ChecksumMismatch` if the checksum doesn't match the layout.
    /// Returns `SyntaxError` if the format is invalid.
    pub fn parseWithChecksum(
        alloc: Allocator,
        str: []const u8,
    ) (ParseError || error{ChecksumMismatch})!Layout {
        // If the string is less than 5 characters, it can't possibly
        // be correct. 4-char checksum + comma. In practice it should
        // be even longer, but that'll fail parse later.
        if (str.len < 5) return error.SyntaxError;
        if (str[4] != ',') return error.SyntaxError;

        // The layout string should start with a 4-character checksum.
        const checksum: Checksum = .calculate(str[5..]);
        if (!std.mem.startsWith(
            u8,
            str,
            &checksum.asString(),
        )) return error.ChecksumMismatch;

        // Checksum matches, parse the rest.
        return try parse(alloc, str[5..]);
    }

    /// Parse a layout string into a Layout structure. The given allocator
    /// will be used for all allocations within the layout. Note that
    /// individual nodes can't be freed so this allocator must be some
    /// kind of arena allocator.
    ///
    /// The layout string must be fully provided as a single string.
    /// Layouts are generally small so this should not be a problem.
    ///
    /// Tmux layout strings have the following format:
    ///
    /// - WxH,X,Y,ID Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - WxH,X,Y{...} Horizontal split (left-right), children comma-separated
    /// - WxH,X,Y[...] Vertical split (top-bottom), children comma-separated
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }

    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        // Find the first `x` to grab the width.
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; // Consume `x`
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find the height, up to a comma.
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; // Consume `,`
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find X
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; // Consume `,`
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find Y, which can end in any of `,{,[`
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; // Don't consume the delimiter!
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Determine our child node.
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                // Consume the delimiter
                offset.* += 1;

                // Leaf pane. Read up to `,}]` because we may be in
                // a set of nodes. If none exist, end of string is fine.
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;

                defer offset.* += idx; // Consume the pane ID, not the delimiter
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;

                break :content .{ .pane = pane_id };
            },

            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);

                // Move beyond our opening
                offset.* += 1;

                while (true) {
                    try nodes.append(alloc, try parseNext(
                        alloc,
                        str,
                        offset,
                    ));

                    // We should not reach the end of string here because
                    // we expect a closing bracket.
                    if (offset.* >= str.len) return error.SyntaxError;

                    // If it is a comma, we expect another node.
                    if (str[offset.*] == ',') {
                        offset.* += 1; // Consume
                        continue;
                    }

                    // We expect a closing bracket now.
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }

                    // Successfully parsed all children.
                    offset.* += 1; // Consume closing bracket
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },

            // indexOfAny above guarantees we have only the above
            else => unreachable,
        };

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }

    /// Whether two layouts split the same panes the same way: the same
    /// tree of splits, in the same directions, with the same panes in the
    /// same places. Sizes are not compared.
    pub fn sameShape(a: Layout, b: Layout) bool {
        return switch (a.content) {
            .pane => |id| switch (b.content) {
                .pane => |other| id == other,
                else => false,
            },
            .horizontal => |children| switch (b.content) {
                .horizontal => |others| sameChildren(children, others),
                else => false,
            },
            .vertical => |children| switch (b.content) {
                .vertical => |others| sameChildren(children, others),
                else => false,
            },
        };
    }

    fn sameChildren(a: []const Layout, b: []const Layout) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!sameShape(x, y)) return false;
        return true;
    }

    /// How `arrange` shares a split between its children.
    pub const Share = enum {
        /// In proportion to the sizes the children have in the layout.
        proportional,

        /// Equally, as Ghostty's equalize_splits does: tmux keeps splits
        /// in one direction as one node, so every child is one share.
        equal,
    };

    /// This layout's splits at another size, `width` by `height`, with
    /// each split shared between its children as `share` says. Every
    /// pane keeps its place; only the sizes change. Null if the size has
    /// too little room for every pane and the dividers between them.
    pub fn arrange(
        self: Layout,
        alloc: Allocator,
        width: usize,
        height: usize,
        share: Share,
    ) Allocator.Error!?Layout {
        return try self.arrangeAt(alloc, 0, 0, width, height, share);
    }

    fn arrangeAt(
        self: Layout,
        alloc: Allocator,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        share: Share,
    ) Allocator.Error!?Layout {
        if (width == 0 or height == 0) return null;
        const children: []const Layout, const across: bool = switch (self.content) {
            .pane => |id| return .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
                .content = .{ .pane = id },
            },
            .horizontal => |v| .{ v, true },
            .vertical => |v| .{ v, false },
        };

        // A one-cell divider between each pair of children.
        const total = if (across) width else height;
        if (total + 1 < children.len * 2) return null;
        const room = total - (children.len - 1);

        // Each child's share of the room, rounded down.
        var weight_sum: usize = 0;
        for (children) |child| weight_sum += weight(child, across, share);
        if (weight_sum == 0) return null;

        const nodes = try alloc.alloc(Layout, children.len);
        var given: usize = 0;
        var sizes = try alloc.alloc(usize, children.len);
        defer alloc.free(sizes);
        for (children, 0..) |child, i| {
            sizes[i] = @max(1, room * weight(child, across, share) / weight_sum);
            given += sizes[i];
        }

        // Rounding down left some room over, or the minimum of one cell
        // took more than there was: the smallest children get what is
        // left over, and the largest give back what is owed.
        while (given != room) {
            var pick: usize = 0;
            for (sizes, 0..) |size, i| {
                if (given < room) {
                    if (size < sizes[pick]) pick = i;
                } else if (size > sizes[pick]) pick = i;
            }
            if (given < room) {
                sizes[pick] += 1;
                given += 1;
            } else {
                if (sizes[pick] <= 1) return null;
                sizes[pick] -= 1;
                given -= 1;
            }
        }

        var offset: usize = 0;
        for (children, sizes, 0..) |child, size, i| {
            nodes[i] = (if (across)
                try child.arrangeAt(alloc, x + offset, y, size, height, share)
            else
                try child.arrangeAt(alloc, x, y + offset, width, size, share)) orelse
                return null;
            offset += size + 1;
        }

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = if (across) .{ .horizontal = nodes } else .{ .vertical = nodes },
        };
    }

    fn weight(self: Layout, across: bool, share: Share) usize {
        return switch (share) {
            .equal => 1,
            .proportional => if (across) self.width else self.height,
        };
    }

    /// Write the layout as tmux writes it, checksum first, which is what
    /// `select-layout` takes.
    pub fn writeWithChecksum(
        self: Layout,
        alloc: Allocator,
    ) Allocator.Error![]u8 {
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        self.write(&body.writer) catch return error.OutOfMemory;
        const str = body.written();
        return try std.fmt.allocPrint(alloc, "{s},{s}", .{
            &Checksum.calculate(str).asString(),
            str,
        });
    }

    fn write(self: Layout, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}x{d},{d},{d}", .{ self.width, self.height, self.x, self.y });
        const children: []const Layout, const open: u8, const close: u8 = switch (self.content) {
            .pane => |id| return writer.print(",{d}", .{id}),
            .horizontal => |v| .{ v, '{', '}' },
            .vertical => |v| .{ v, '[', ']' },
        };
        try writer.writeByte(open);
        for (children, 0..) |child, i| {
            if (i > 0) try writer.writeByte(',');
            try child.write(writer);
        }
        try writer.writeByte(close);
    }
};

pub const Checksum = enum(u16) {
    _,

    /// Calculate the checksum of a tmux layout string.
    /// The algorithm rotates the checksum right by 1 bit (with wraparound)
    /// and adds the ASCII value of each character.
    pub fn calculate(str: []const u8) Checksum {
        var result: u16 = 0;
        for (str) |c| {
            // Rotate right by 1: (result >> 1) + ((result & 1) << 15)
            result = (result >> 1) | ((result & 1) << 15);
            result +%= c;
        }

        return @enumFromInt(result);
    }

    /// Convert the checksum to a 4-character hexadecimal string. This
    /// is always zero-padded to match the tmux implementation
    /// (in layout-custom.c).
    pub fn asString(self: Checksum) [4]u8 {
        const value = @intFromEnum(self);
        const charset = "0123456789abcdef";
        return .{
            charset[(value >> 12) & 0xf],
            charset[(value >> 8) & 0xf],
            charset[(value >> 4) & 0xf],
            charset[value & 0xf],
        };
    }
};

test "simple single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,42");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    try testing.expectEqual(42, layout.content.pane);
}

test "single pane with offset" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "40x12,10,5,7");
    try testing.expectEqual(40, layout.width);
    try testing.expectEqual(12, layout.height);
    try testing.expectEqual(10, layout.x);
    try testing.expectEqual(5, layout.y);
    try testing.expectEqual(7, layout.content.pane);
}

test "single pane large values" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "1920x1080,100,200,999");
    try testing.expectEqual(1920, layout.width);
    try testing.expectEqual(1080, layout.height);
    try testing.expectEqual(100, layout.x);
    try testing.expectEqual(200, layout.y);
    try testing.expectEqual(999, layout.content.pane);
}

test "horizontal split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.horizontal;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(40, children[0].width);
    try testing.expectEqual(24, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(40, children[1].width);
    try testing.expectEqual(24, children[1].height);
    try testing.expectEqual(40, children[1].x);
    try testing.expectEqual(0, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "vertical split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.vertical;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(80, children[0].width);
    try testing.expectEqual(12, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(80, children[1].width);
    try testing.expectEqual(12, children[1].height);
    try testing.expectEqual(0, children[1].x);
    try testing.expectEqual(12, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "horizontal split three panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "120x24,0,0{40x24,0,0,1,40x24,40,0,2,40x24,80,0,3}");
    try testing.expectEqual(120, layout.width);
    try testing.expectEqual(24, layout.height);

    const children = layout.content.horizontal;
    try testing.expectEqual(3, children.len);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(2, children[1].content.pane);
    try testing.expectEqual(3, children[2].content.pane);
}

test "nested horizontal in vertical" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Vertical split with top pane and bottom horizontal split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12{40x12,0,12,2,40x12,40,12,3}]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const vert_children = layout.content.vertical;
    try testing.expectEqual(2, vert_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, vert_children[0].content.pane);

    // Second child is a horizontal split
    const horiz_children = vert_children[1].content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(2, horiz_children[0].content.pane);
    try testing.expectEqual(3, horiz_children[1].content.pane);
}

test "nested vertical in horizontal" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Horizontal split with left pane and right vertical split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const horiz_children = layout.content.horizontal;
    try testing.expectEqual(2, horiz_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, horiz_children[0].content.pane);

    // Second child is a vertical split
    const vert_children = horiz_children[1].content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(2, vert_children[0].content.pane);
    try testing.expectEqual(3, vert_children[1].content.pane);
}

test "deeply nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Three levels deep
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],40x24,40,0,3}");

    const horiz = layout.content.horizontal;
    try testing.expectEqual(2, horiz.len);

    const vert = horiz[0].content.vertical;
    try testing.expectEqual(2, vert.len);
    try testing.expectEqual(1, vert[0].content.pane);
    try testing.expectEqual(2, vert[1].content.pane);

    try testing.expectEqual(3, horiz[1].content.pane);
}

test "syntax error empty string" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), ""));
}

test "syntax error missing width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "x24,0,0,1"));
}

test "syntax error missing height" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x,0,0,1"));
}

test "syntax error missing x" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,,0,1"));
}

test "syntax error missing y" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,,1"));
}

test "syntax error missing pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,"));
}

test "syntax error non-numeric width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "abcx24,0,0,1"));
}

test "syntax error non-numeric pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,abc"));
}

test "syntax error unclosed horizontal bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1"));
}

test "syntax error unclosed vertical bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1"));
}

test "syntax error mismatched brackets" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1]"));
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1}"));
}

test "syntax error trailing data" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,1extra"));
}

test "syntax error no x separator" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "8024,0,0,1"));
}

test "syntax error no content delimiter" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0"));
}

// parseWithChecksum tests

test "parseWithChecksum valid" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parseWithChecksum(arena.allocator(), "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
}

test "parseWithChecksum mismatch" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ChecksumMismatch, Layout.parseWithChecksum(arena.allocator(), "0000,80x24,0,0{40x24,0,0,1,40x24,40,0,2}"));
}

test "parseWithChecksum too short" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62"));
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), ""));
}

test "parseWithChecksum missing comma" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62x159x48,0,0"));
}

// Checksum tests

test "checksum empty string" {
    const checksum = Checksum.calculate("");
    try testing.expectEqual(@as(u16, 0), @intFromEnum(checksum));
    try testing.expectEqualStrings("0000", &checksum.asString());
}

test "checksum single character" {
    // 'A' = 65, first iteration: csum = 0 >> 1 | 0 = 0, then 0 + 65 = 65
    const checksum = Checksum.calculate("A");
    try testing.expectEqual(@as(u16, 65), @intFromEnum(checksum));
    try testing.expectEqualStrings("0041", &checksum.asString());
}

test "checksum two characters" {
    // 'A' (65): csum = 0, rotate = 0, add 65 => 65
    // 'B' (66): csum = 65, rotate => (65 >> 1) | ((65 & 1) << 15) = 32 | 32768 = 32800
    //           add 66 => 32800 + 66 = 32866
    const checksum = Checksum.calculate("AB");
    try testing.expectEqual(@as(u16, 32866), @intFromEnum(checksum));
    try testing.expectEqualStrings("8062", &checksum.asString());
}

test "checksum simple layout" {
    const checksum = Checksum.calculate("80x24,0,0,42");
    try testing.expectEqualStrings("d962", &checksum.asString());
}

test "checksum horizontal split layout" {
    const checksum = Checksum.calculate("80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqualStrings("f8f9", &checksum.asString());
}

test "checksum asString zero padding" {
    // Value 0x000f should produce "000f"
    const checksum: Checksum = @enumFromInt(0x000f);
    try testing.expectEqualStrings("000f", &checksum.asString());
}

test "checksum asString all digits" {
    // Value 0x1234 should produce "1234"
    const checksum: Checksum = @enumFromInt(0x1234);
    try testing.expectEqualStrings("1234", &checksum.asString());
}

test "checksum asString with letters" {
    // Value 0xabcd should produce "abcd"
    const checksum: Checksum = @enumFromInt(0xabcd);
    try testing.expectEqualStrings("abcd", &checksum.asString());
}

test "checksum asString max value" {
    // Value 0xffff should produce "ffff"
    const checksum: Checksum = @enumFromInt(0xffff);
    try testing.expectEqualStrings("ffff", &checksum.asString());
}

test "checksum wraparound" {
    const checksum = Checksum.calculate("\xff\xff\xff\xff\xff\xff\xff\xff");
    try testing.expectEqualStrings("03fc", &checksum.asString());
}

test "checksum deterministic" {
    // Same input should always produce same output
    const str = "159x48,0,0{79x48,0,0,79x48,80,0}";
    const checksum1 = Checksum.calculate(str);
    const checksum2 = Checksum.calculate(str);
    try testing.expectEqual(checksum1, checksum2);
}

test "checksum different inputs different outputs" {
    const checksum1 = Checksum.calculate("80x24,0,0,1");
    const checksum2 = Checksum.calculate("80x24,0,0,2");
    try testing.expect(@intFromEnum(checksum1) != @intFromEnum(checksum2));
}

test "checksum known tmux layout bb62" {
    // From tmux documentation: "bb62,159x48,0,0{79x48,0,0,79x48,80,0}"
    // The checksum "bb62" corresponds to the layout "159x48,0,0{79x48,0,0,79x48,80,0}"
    const checksum = Checksum.calculate("159x48,0,0{79x48,0,0,79x48,80,0}");
    try testing.expectEqualStrings("bb62", &checksum.asString());
}

test "write a layout as tmux does" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}";
    const layout: Layout = try .parseWithChecksum(alloc, str);
    try testing.expectEqualStrings(str, try layout.writeWithChecksum(alloc));
}

test "same shape ignores sizes, not panes or directions" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a: Layout = try .parse(alloc, "80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    const b: Layout = try .parse(alloc, "100x30,0,0{20x30,0,0,1,79x30,21,0,2}");
    const swapped: Layout = try .parse(alloc, "80x24,0,0{40x24,0,0,2,39x24,41,0,1}");
    const turned: Layout = try .parse(alloc, "80x24,0,0[80x12,0,0,1,80x11,0,13,2]");
    const more: Layout = try .parse(alloc, "80x24,0,0{40x24,0,0,1,19x24,41,0,2,19x24,61,0,3}");
    try testing.expect(a.sameShape(b));
    try testing.expect(!a.sameShape(swapped));
    try testing.expect(!a.sameShape(turned));
    try testing.expect(!a.sameShape(more));
}

test "arrange keeps proportions at a new size" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 3:1 across, and an even split down the right.
    const saved: Layout = try .parse(
        alloc,
        "81x24,0,0{60x24,0,0,1,20x24,61,0[20x12,61,0,2,20x11,61,13,3]}",
    );
    const at = (try saved.arrange(alloc, 161, 48, .proportional)).?;
    try testing.expectEqualStrings(
        "161x48,0,0{120x48,0,0,1,40x48,121,0[40x24,121,0,2,40x23,121,25,3]}",
        (try at.writeWithChecksum(alloc))[5..],
    );
}

test "arrange equally" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const uneven: Layout = try .parse(
        alloc,
        "80x24,0,0{10x24,0,0,1,50x24,11,0,2,18x24,62,0,3}",
    );
    const at = (try uneven.arrange(alloc, 80, 24, .equal)).?;
    try testing.expectEqualStrings(
        "80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}",
        (try at.writeWithChecksum(alloc))[5..],
    );

    // No room for three panes and two dividers.
    try testing.expect(try uneven.arrange(alloc, 4, 24, .equal) == null);
}
