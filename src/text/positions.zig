const std = @import("std");
pub const Encoding = @import("types.zig").Encoding;
pub const Position = @import("types.zig").Position;
/// Preserve replacement decoding without calling the standard decoder on a
/// truncated sequence. Its length-specific routines require a matching lead byte.
pub fn decodeScalar(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0xfffd;
    const width = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 0xfffd;
    if (width != bytes.len) return 0xfffd;
    return std.unicode.utf8Decode(bytes) catch 0xfffd;
}
pub const Index = struct {
    starts: std.ArrayList(u32) = .empty,
    pub fn init(gpa: std.mem.Allocator, text: []const u8) !Index {
        return initCancellable(gpa, text, null);
    }
    pub fn initCancellable(gpa: std.mem.Allocator, text: []const u8, cancel: ?*const std.atomic.Value(bool)) !Index {
        return initImpl(false, gpa, text, cancel, null);
    }
    pub fn initBackground(gpa: std.mem.Allocator, text: []const u8, cancel: ?*const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Index {
        return initImpl(true, gpa, text, cancel, waiting);
    }
    fn initImpl(comptime background: bool, gpa: std.mem.Allocator, text: []const u8, cancel: ?*const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Index {
        var self: Index = .{};
        errdefer self.deinit(gpa);
        try self.starts.append(gpa, 0);
        var i: usize = 0;
        var next_poll: usize = 0;
        while (i < text.len) : (i += 1) {
            if (i >= next_poll) {
                next_poll = i +| 4096;
                if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
                if (background) if (waiting) |flag| if (flag.load(.acquire) != 0) return error.Yield;
            }
            if (text[i] == '\r') {
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                try self.starts.append(gpa, std.math.cast(u32, i + 1) orelse return error.SourceTooLarge);
            } else if (text[i] == '\n') try self.starts.append(gpa, std.math.cast(u32, i + 1) orelse return error.SourceTooLarge);
        }
        return self;
    }
    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        self.starts.deinit(gpa);
    }
    pub fn position(self: Index, text: []const u8, raw: usize, encoding: Encoding) Position {
        return self.positionCancellable(text, raw, encoding, null) catch unreachable;
    }
    pub fn positionCancellable(self: Index, text: []const u8, raw: usize, encoding: Encoding, cancel: ?*const std.atomic.Value(bool)) !Position {
        return self.positionImpl(false, text, raw, encoding, cancel, null);
    }
    pub fn positionBackground(self: Index, text: []const u8, raw: usize, encoding: Encoding, cancel: ?*const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Position {
        return self.positionImpl(true, text, raw, encoding, cancel, waiting);
    }
    fn positionImpl(self: Index, comptime background: bool, text: []const u8, raw: usize, encoding: Encoding, cancel: ?*const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Position {
        const offset = @min(raw, text.len);
        var lo: usize = 0;
        var hi = self.starts.items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts.items[mid] <= offset) lo = mid else hi = mid;
        }
        var i: usize = self.starts.items[lo];
        var count: usize = 0;
        var next_poll: usize = i;
        while (i < offset and text[i] != '\r' and text[i] != '\n') {
            if (i >= next_poll) {
                next_poll = i +| 4096;
                if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
                if (background) if (waiting) |flag| if (flag.load(.acquire) != 0) return error.Yield;
            }
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + n, offset);
            const scalar = decodeScalar(text[i..end]);
            count += switch (encoding) {
                .utf8 => end - i,
                .utf16 => if (scalar > 0xffff) @as(usize, 2) else 1,
                .utf32 => 1,
            };
            i = end;
        }
        return .{ .line = lo, .character = count };
    }
};
test "astral, BOM, CRLF, CR, LF and clamping" {
    const text = "\xef\xbb\xbf😀x\r\na\rb\nc";
    var index = try Index.init(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, index.position(text, 7, .utf16));
    try std.testing.expectEqual(Position{ .line = 0, .character = 7 }, index.position(text, 7, .utf8));
    try std.testing.expectEqual(Position{ .line = 0, .character = 2 }, index.position(text, 7, .utf32));
    try std.testing.expectEqual(Position{ .line = 3, .character = 1 }, index.position(text, 999, .utf16));
}

test "column conversion notices cancellation at unaligned Unicode line starts" {
    const text = "x\r\n😀😀😀";
    var index = try Index.init(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, index.positionCancellable(text, text.len, .utf16, &cancel));
}

test "background position work yields to syntax without retaining temporary storage" {
    const waiting: std.atomic.Value(usize) = .init(1);
    try std.testing.expectError(error.Yield, Index.initBackground(std.testing.allocator, "abc", null, &waiting));
    var index = try Index.init(std.testing.allocator, "abc");
    defer index.deinit(std.testing.allocator);
    try std.testing.expectError(error.Yield, index.positionBackground("abc", 3, .utf16, null, &waiting));
}

test "truncated UTF-8 and positions inside a scalar do not trap" {
    inline for (.{ "\xe2\x82", "\xf0\x9f\x98", "\xff", "\xe2X\x82" }) |source| {
        var index = try Index.init(std.testing.allocator, source);
        defer index.deinit(std.testing.allocator);
        try std.testing.expectEqual(Position{ .line = 0, .character = 1 }, index.position(source, source.len, .utf16));
    }
    var index = try Index.init(std.testing.allocator, "😀");
    defer index.deinit(std.testing.allocator);
    for (1..4) |end| try std.testing.expectEqual(Position{ .line = 0, .character = 1 }, index.position("😀", end, .utf16));
}
