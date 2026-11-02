//! Compact source-independent coordinates. Construction borrows source only.
const std = @import("std");
const pos = @import("types.zig");
const Unicode = struct { units: u32, bytes: u32 };
const crlf: u32 = 0x80000000;
pub const Index = struct {
    lines: []u32 = &.{},
    unicode: []Unicode = &.{},
    source_len: u32 = 0,
    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
        gpa.free(self.unicode);
        self.* = .{};
    }
    pub fn bytes(self: Index) usize {
        return self.lines.len * 4 + self.unicode.len * 8;
    }
    /// Source byte to the encoding selected when this index was built.
    /// Binary searches avoid rescanning long lines for each outline entry.
    pub fn positionAt(self: Index, raw: u32) pos.Position {
        const byte = @min(raw, self.source_len);
        var lo: usize = 0;
        var hi = self.lines.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if ((self.lines[mid] & ~crlf) <= byte) lo = mid else hi = mid;
        }
        return .{ .line = lo, .character = self.unitsAt(byte) - self.unitsAt(self.lines[lo] & ~crlf) };
    }
    fn unitsAt(self: Index, byte: u32) u32 {
        var lo: usize = 0;
        var hi = self.unicode.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.unicode[mid].bytes <= byte) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) byte else byte - (self.unicode[lo - 1].bytes - self.unicode[lo - 1].units);
    }
    pub fn byteAt(self: Index, point: pos.Position) ?u32 {
        if (point.line >= self.lines.len) return null;
        const start = self.unitsAt(self.lines[point.line] & ~crlf);
        const end = if (point.line + 1 == self.lines.len) self.unitsAt(self.source_len) else self.unitsAt(self.lines[point.line + 1] & ~crlf) - @as(u32, if (self.lines[point.line + 1] & crlf != 0) 2 else 1);
        if (point.character > end - start) return null;
        const target: u32 = start + @as(u32, @intCast(point.character));
        var lo: usize = 0;
        var hi = self.unicode.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.unicode[mid].units <= target) lo = mid + 1 else hi = mid;
        }
        const byte = target + if (lo == 0) @as(u32, 0) else self.unicode[lo - 1].bytes - self.unicode[lo - 1].units;
        return byte;
    }
};
pub const Builder = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    cancel: *const std.atomic.Value(bool),
    waiting: ?*const std.atomic.Value(usize),
    lines: std.ArrayList(u32) = .empty,
    unicode: std.ArrayList(Unicode) = .empty,
    pub fn deinit(self: *Builder) void {
        self.lines.deinit(self.gpa);
        self.unicode.deinit(self.gpa);
    }
    fn poll(self: *Builder) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        if (self.waiting) |flag| if (flag.load(.acquire) > 0) return error.Yield;
    }
    fn budget(self: *Builder, other_bytes: usize, max_bytes: usize) !void {
        if (other_bytes + self.lines.items.len * 4 + self.unicode.items.len * 8 > max_bytes) return error.ContextLimit;
    }
    pub fn finish(self: *Builder) !Index {
        var index: Index = .{ .source_len = @intCast(self.source.len) };
        errdefer index.deinit(self.gpa);
        index.lines = try self.lines.toOwnedSlice(self.gpa);
        index.unicode = try self.unicode.toOwnedSlice(self.gpa);
        return index;
    }
    pub fn scan(self: *Builder, encoding: pos.Encoding, other_bytes: usize, max_bytes: usize) !void {
        try self.lines.append(self.gpa, 0);
        var i: usize = 0;
        var units: u32 = 0;
        var next: usize = 0;
        while (i < self.source.len) {
            if (i >= next) {
                try self.poll();
                try self.budget(other_bytes, max_bytes);
                next = i + 4096;
            }
            if (self.source.len - i >= 8) {
                const V = @Vector(8, u8);
                const v: V = self.source[i..][0..8].*;
                const special = (v >= @as(V, @splat(128))) | (v == @as(V, @splat('\r'))) | (v == @as(V, @splat('\n')));
                const n: usize = if (std.simd.firstTrue(special)) |n| n else 8;
                if (n > 0) {
                    i += n;
                    units += @intCast(n);
                    continue;
                }
            }
            const byte = self.source[i];
            if (byte == '\r' or byte == '\n') {
                i += 1;
                units += 1;
                const pair = byte == '\r' and i < self.source.len and self.source[i] == '\n';
                if (pair) {
                    i += 1;
                    units += 1;
                }
                try self.lines.append(self.gpa, @as(u32, @intCast(i)) | if (pair) crlf else 0);
            } else {
                const width = @min(std.unicode.utf8ByteSequenceLength(byte) catch 1, self.source.len - i);
                const scalar = @import("positions.zig").decodeScalar(self.source[i..][0..width]);
                const count: u32 = switch (encoding) {
                    .utf8 => @intCast(width),
                    .utf16 => if (scalar > 0xffff) 2 else 1,
                    .utf32 => 1,
                };
                i += width;
                units += count;
                if (count != width) try self.unicode.append(self.gpa, .{ .units = units, .bytes = @intCast(i) });
            }
        }
        try self.budget(other_bytes, max_bytes);
    }
};

test "compact coordinates agree with source-backed positions at scalar and line boundaries" {
    const source = "\xef\xbb\xbfA😀é\r\nβ\rc\n\xffZ\xe2\x82";
    const cancel: std.atomic.Value(bool) = .init(false);
    const Positions = @import("positions.zig").Index;
    var positions = try Positions.init(std.testing.allocator, source);
    defer positions.deinit(std.testing.allocator);
    inline for (.{ pos.Encoding.utf8, .utf16, .utf32 }) |encoding| {
        var builder: Builder = .{ .gpa = std.testing.allocator, .source = source, .cancel = &cancel, .waiting = null };
        defer builder.deinit();
        try builder.scan(encoding, 0, 1024);
        var index = try builder.finish();
        defer index.deinit(std.testing.allocator);
        var at: usize = 0;
        while (true) {
            const expected = positions.position(source, at, encoding);
            try std.testing.expectEqualDeep(expected, index.positionAt(@intCast(at)));
            try std.testing.expectEqual(@as(?u32, @intCast(at)), index.byteAt(expected));
            if (at == source.len) break;
            if (source[at] == '\r' and at + 1 < source.len and source[at + 1] == '\n') {
                at += 2;
            } else {
                at += @min(std.unicode.utf8ByteSequenceLength(source[at]) catch 1, source.len - at);
            }
        }
        try std.testing.expectEqualDeep(index.positionAt(source.len), index.positionAt(source.len + 100));
        try std.testing.expectEqual(@as(?u32, null), index.byteAt(.{ .line = 99, .character = 0 }));
        try std.testing.expectEqual(@as(?u32, null), index.byteAt(.{ .line = 0, .character = 99 }));
    }
}

test "coordinate construction preserves cancellation yield budget and allocation cleanup" {
    const Harness = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const cancel: std.atomic.Value(bool) = .init(false);
            var builder: Builder = .{ .gpa = gpa, .source = "a😀\r\nbé\rc\n", .cancel = &cancel, .waiting = null };
            defer builder.deinit();
            try builder.scan(.utf16, 12, 1024);
            var index = try builder.finish();
            defer index.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
    var cancel: std.atomic.Value(bool) = .init(true);
    const waiting: std.atomic.Value(usize) = .init(1);
    var cancelled: Builder = .{ .gpa = std.testing.allocator, .source = "abc", .cancel = &cancel, .waiting = null };
    defer cancelled.deinit();
    try std.testing.expectError(error.Cancelled, cancelled.scan(.utf16, 0, 1024));
    cancel.store(false, .release);
    var yielded: Builder = .{ .gpa = std.testing.allocator, .source = "abc", .cancel = &cancel, .waiting = &waiting };
    defer yielded.deinit();
    try std.testing.expectError(error.Yield, yielded.scan(.utf16, 0, 1024));
    var limited: Builder = .{ .gpa = std.testing.allocator, .source = "abc", .cancel = &cancel, .waiting = null };
    defer limited.deinit();
    try std.testing.expectError(error.ContextLimit, limited.scan(.utf16, 1024, 1024));
}
