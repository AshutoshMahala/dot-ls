//! Source spans are captured during parsing; identity and ranges are built later.
const std = @import("std");
const dot = @import("dot_parser");
const pos = @import("../text/positions.zig");
pub const Range = struct { start: pos.Position, end: pos.Position };
const End = struct { line: u32, character: u32 };
const extended: u32 = 0x80000000;
pub const Entry = struct { line: u32, character: u32, length: u32, symbol: u32 };
pub const max_bytes = 128 * 1024 * 1024;
pub const Index = struct {
    entries: []Entry = &.{},
    ends: []End = &.{},
    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.ends);
        self.* = .{};
    }
    pub fn bytes(self: Index) usize {
        return self.entries.len * @sizeOf(Entry) + self.ends.len * @sizeOf(End);
    }
    pub fn range(self: Index, entry: Entry) Range {
        const end: End = if (entry.length & extended != 0) self.ends[entry.length & ~extended] else .{ .line = entry.line, .character = entry.character + entry.length };
        return .{ .start = .{ .line = entry.line, .character = entry.character }, .end = .{ .line = end.line, .character = end.character } };
    }
    pub fn symbolAt(self: Index, point: pos.Position) ?u32 {
        var lo: usize = 0;
        var hi = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.entries[mid];
            if (e.line < point.line or (e.line == point.line and e.character <= point.character)) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const e = self.entries[lo - 1];
        const end = self.range(e).end;
        if (point.line > end.line or (point.line == end.line and point.character >= end.character)) return null;
        return e.symbol;
    }
};
const Occurrence = dot.Name;
const Names = std.HashMapUnmanaged(dot.Name, u32, NameContext, 80);
const NameContext = struct {
    source: []const u8,
    pub fn hash(self: NameContext, span: dot.Name) u64 {
        const raw = span.slice(self.source);
        if (raw[0] != '"' and raw[0] != '<') return std.hash.Wyhash.hash(0, raw);
        return (dot.identifier.fromName(self.source, span).hash() catch unreachable);
    }
    pub fn eql(self: NameContext, a: dot.Name, b: dot.Name) bool {
        const left = a.slice(self.source);
        const right = b.slice(self.source);
        if (left[0] != '"' and left[0] != '<' and right[0] != '"' and right[0] != '<') return std.mem.eql(u8, left, right);
        return (dot.identifier.fromName(self.source, a).eql(dot.identifier.fromName(self.source, b)) catch unreachable);
    }
};
pub const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    cancel: *const std.atomic.Value(bool),
    waiting: ?*const std.atomic.Value(usize) = null,
    names: Names = .empty,
    occurrences: std.ArrayList(Occurrence) = .empty,
    failed: bool = false,
    ordered: bool = true,
    pub fn init(allocator: std.mem.Allocator, source: []const u8, cancel: *const std.atomic.Value(bool)) Builder {
        return .{ .allocator = allocator, .source = source, .cancel = cancel };
    }
    pub fn deinit(self: *Builder) void {
        self.names.deinit(self.allocator);
        self.occurrences.deinit(self.allocator);
    }
    pub fn emit(context: *anyopaque, span: dot.Name) void {
        const self: *Builder = @ptrCast(@alignCast(context));
        if (self.failed or self.cancel.load(.acquire)) return;
        self.add(span) catch {
            self.failed = true;
        };
    }
    fn add(self: *Builder, span: dot.Name) !void {
        if (self.occurrences.items.len >= max_bytes / @sizeOf(Entry)) return error.IndexLimit;
        if (self.occurrences.items.len > 0 and self.occurrences.items[self.occurrences.items.len - 1].start > span.start) self.ordered = false;
        try self.occurrences.append(self.allocator, span);
    }
    fn poll(self: *Builder) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        if (self.waiting) |pending| if (pending.load(.acquire) > 0) return error.Yield;
    }
    pub fn finish(self: *Builder, encoding: pos.Encoding) !Index {
        if (self.failed) return error.IndexUnavailable;
        errdefer {
            self.names.deinit(self.allocator);
            self.names = .empty;
        }
        try self.poll();
        const spans = self.occurrences.items;
        const scratch = try self.allocator.alloc(Occurrence, if (self.ordered) 0 else spans.len);
        defer self.allocator.free(scratch);
        var input = spans;
        var output = scratch;
        for (0..if (self.ordered) @as(usize, 0) else 4) |pass| {
            var counts: [256]usize = @splat(0);
            const shift: u5 = @intCast(pass * 8);
            for (input, 0..) |entry, n| {
                if (n % 4096 == 0 and self.cancel.load(.acquire)) return error.Cancelled;
                counts[(entry.start >> shift) & 255] += 1;
            }
            var total: usize = 0;
            for (&counts) |*count| {
                const size = count.*;
                count.* = total;
                total += size;
            }
            for (input, 0..) |entry, n| {
                if (n % 4096 == 0 and self.cancel.load(.acquire)) return error.Cancelled;
                const bucket = (entry.start >> shift) & 255;
                output[counts[bucket]] = entry;
                counts[bucket] += 1;
            }
            std.mem.swap([]Occurrence, &input, &output);
            // Preserve a complete permutation if a higher-priority parse arrives.
            if (self.waiting) |pending| if (pending.load(.acquire) > 0) {
                if (input.ptr != spans.ptr) @memcpy(spans, input);
                return error.Yield;
            };
        }
        self.ordered = true;
        // Four passes leave the result in spans. Retrying after a yield can reuse it.
        self.names.deinit(self.allocator);
        self.names = .empty;
        const entries = try self.allocator.alloc(Entry, spans.len);
        errdefer self.allocator.free(entries);
        for (input, entries, 0..) |span, *entry, n| {
            if (n % 4096 == 0) try self.poll();
            const found = try self.names.getOrPutContext(self.allocator, span, .{ .source = self.source });
            if (!found.found_existing) {
                if (self.names.count() > 4_000_000) return error.IndexLimit;
                found.value_ptr.* = self.names.count() - 1;
            }
            entry.symbol = found.value_ptr.*;
        }
        var ends: std.ArrayList(End) = .empty;
        errdefer ends.deinit(self.allocator);
        var cursor: Cursor = .{ .source = self.source, .encoding = encoding, .cancel = self.cancel, .waiting = self.waiting };
        for (input, entries) |span, *entry| {
            try cursor.advance(span.start);
            const start = cursor.position;
            try cursor.advance(@as(usize, span.start) + span.len);
            const multiline = start.line != cursor.position.line;
            const length: u32 = if (!multiline) @intCast(cursor.position.character - start.character) else extended | @as(u32, @intCast(ends.items.len));
            if (multiline) try ends.append(self.allocator, .{ .line = @intCast(cursor.position.line), .character = @intCast(cursor.position.character) });
            if (entries.len * @sizeOf(Entry) + ends.items.len * @sizeOf(End) > max_bytes) return error.IndexLimit;
            entry.* = .{ .line = @intCast(start.line), .character = @intCast(start.character), .length = length, .symbol = entry.symbol };
        }
        try self.poll();
        return .{ .entries = entries, .ends = try ends.toOwnedSlice(self.allocator) };
    }
};
const Cursor = struct {
    source: []const u8,
    encoding: pos.Encoding,
    cancel: *const std.atomic.Value(bool),
    offset: usize = 0,
    position: pos.Position = .{ .line = 0, .character = 0 },
    next_poll: usize = 0,
    waiting: ?*const std.atomic.Value(usize) = null,
    fn advance(self: *Cursor, end: usize) !void {
        while (self.offset < end) {
            if (self.offset >= self.next_poll) {
                self.next_poll = self.offset +| 4096;
                if (self.cancel.load(.acquire)) return error.Cancelled;
                if (self.waiting) |pending| if (pending.load(.acquire) > 0) return error.Yield;
            }
            const V = @Vector(8, u8);
            if (end - self.offset >= 8) {
                const bytes: V = self.source[self.offset..][0..8].*;
                const special = (bytes >= @as(V, @splat(128))) | (bytes == @as(V, @splat('\r'))) | (bytes == @as(V, @splat('\n')));
                const count: usize = if (std.simd.firstTrue(special)) |n| n else 8;
                if (count > 0) {
                    self.offset += count;
                    self.position.character += count;
                    continue;
                }
            }
            const byte = self.source[self.offset];
            if (byte == '\r' or byte == '\n') {
                self.offset += 1;
                if (byte == '\r' and self.offset < self.source.len and self.source[self.offset] == '\n') self.offset += 1;
                self.position.line += 1;
                self.position.character = 0;
            } else if (byte < 0x80) {
                self.offset += 1;
                self.position.character += 1;
            } else {
                const width = @min(std.unicode.utf8ByteSequenceLength(byte) catch 1, end - self.offset);
                const scalar = pos.decodeScalar(self.source[self.offset..][0..width]);
                self.position.character += switch (self.encoding) {
                    .utf8 => width,
                    .utf16 => if (scalar > 0xffff) @as(usize, 2) else 1,
                    .utf32 => 1,
                };
                self.offset += width;
            }
        }
    }
};

test "index failure does not escape the observer, and cancelled builds release storage" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var builder = Builder.init(failing.allocator(), "a", &cancel);
    defer builder.deinit();
    Builder.emit(&builder, .{ .start = 0, .len = 1 });
    try std.testing.expect(builder.failed);
    try std.testing.expectError(error.IndexUnavailable, builder.finish(.utf16));
    var good = Builder.init(std.testing.allocator, "a", &cancel);
    defer good.deinit();
    Builder.emit(&good, .{ .start = 0, .len = 1 });
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, good.finish(.utf16));
}

test "compact ranges keep multiline IDs and all allocation failures release storage" {
    const text = "a \"a\" \"a\nb\"";
    var cancel: std.atomic.Value(bool) = .init(false);
    for (0..12) |failure_at| {
        var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_at });
        var builder = Builder.init(failure.allocator(), text, &cancel);
        defer builder.deinit();
        for ([_]dot.Span{ .{ .start = 2, .len = 3 }, .{ .start = 0, .len = 1 }, .{ .start = 6, .len = 5 } }) |span| Builder.emit(&builder, try dot.identifier.check(text, span));
        var index = builder.finish(.utf16) catch continue;
        defer index.deinit(failure.allocator());
        try std.testing.expectEqual(@as(usize, 3), index.entries.len);
        try std.testing.expectEqual(index.entries[0].symbol, index.entries[1].symbol);
        try std.testing.expectEqual(@as(usize, 1), index.range(index.entries[2]).end.line);
        try std.testing.expectEqual(@as(usize, 56), index.bytes());
    }
}

test "foreground work yields indexing without publishing partial storage" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var waiting: std.atomic.Value(usize) = .init(1);
    var builder = Builder.init(std.testing.allocator, "a", &cancel);
    defer builder.deinit();
    Builder.emit(&builder, .{ .start = 0, .len = 1 });
    builder.waiting = &waiting;
    try std.testing.expectError(error.Yield, builder.finish(.utf16));
    waiting.store(0, .release);
    var index = try builder.finish(.utf16);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
}
