const std = @import("std");
pub const Mode = enum { arena, buffer, inplace };
/// One message owns all decoded data. The packet stays alive until deinit.
/// Do not move this value after parse: managed arrays borrow its allocator context.
pub const Message = struct {
    allocator: std.mem.Allocator,
    value: std.json.Value = .null,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    buffer: ?[]u8 = null,
    fixed: std.heap.FixedBufferAllocator = undefined,
    used_fallback: bool = false,
    inplace: bool = false,
    /// Mutate only string bytes that the standard scanner has already consumed.
    /// All string views borrow the packet; metadata belongs to the arena.
    pub fn parseInPlace(self: *Message, bytes: []u8) !void {
        std.debug.assert(self.buffer == null and self.parsed == null);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        var source: InPlaceTokens = .{ .scanner = std.json.Scanner.initCompleteInput(arena.allocator(), bytes), .bytes = bytes };
        defer source.scanner.deinit();
        self.value = try std.json.parseFromTokenSourceLeaky(std.json.Value, arena.allocator(), &source, .{ .max_value_len = bytes.len });
        self.parsed = .{ .arena = arena, .value = self.value };
        self.inplace = true;
    }
    pub fn parse(self: *Message, bytes: []const u8, mode: Mode) !void {
        std.debug.assert(mode != .inplace);
        std.debug.assert(self.buffer == null and self.parsed == null);
        if (mode == .buffer) {
            // Leave room for geometric string growth while allowing it to resize
            // in place. Unused mapped capacity is not necessarily resident.
            const capacity = try std.math.add(usize, try std.math.mul(usize, bytes.len, 2), 16 * 1024);
            // This region is backing storage, not initialized JSON values. The
            // JSON parser initializes the slices it uses before reading them. Avoid
            // poisoning unused capacity in ReleaseSafe: never read that capacity.
            const pointer = self.allocator.rawAlloc(capacity, .of(u8), @returnAddress()) orelse return error.OutOfMemory;
            const region = pointer[0..capacity];
            self.buffer = region;
            self.fixed = .init(region);
            self.value = std.json.parseFromSliceLeaky(std.json.Value, self.fixed.allocator(), bytes, .{ .max_value_len = bytes.len }) catch |err| {
                self.allocator.rawFree(region, .of(u8), @returnAddress());
                self.buffer = null;
                if (err != error.OutOfMemory) return err;
                // Metadata-heavy messages can exceed the fast-path budget. Retry
                // from the original immutable packet; no partial value escapes.
                self.used_fallback = true;
                try self.parseArena(bytes);
                return;
            };
        } else try self.parseArena(bytes);
    }
    fn parseArena(self: *Message, bytes: []const u8) !void {
        self.parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{ .max_value_len = bytes.len });
        self.value = self.parsed.?.value;
    }
    pub fn deinit(self: *Message) void {
        if (self.parsed) |parsed| parsed.deinit();
        // Matches rawAlloc's exact extent/alignment. No decoded view may outlive
        // this owner. Raw release avoids touching unused backing capacity.
        if (self.buffer) |buffer| self.allocator.rawFree(buffer, .of(u8), @returnAddress());
        self.* = undefined;
    }
};
test "request buffer preserves escapes, arrays, and borrowed source" {
    const bytes = "{\"text\":\"a\\n\\uD83D\\uDE00\",\"array\":[1,2]}";
    var message: Message = .{ .allocator = std.testing.allocator };
    defer message.deinit();
    try message.parse(bytes, .buffer);
    try std.testing.expectEqualStrings("a\n😀", message.value.object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 2), message.value.object.get("array").?.array.items[1].integer);
    try std.testing.expect(!message.used_fallback);
}
test "metadata-heavy request retries without leaking" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.append(std.testing.allocator, '[');
    for (0..2000) |i| {
        if (i != 0) try bytes.append(std.testing.allocator, ',');
        try bytes.append(std.testing.allocator, '0');
    }
    try bytes.append(std.testing.allocator, ']');
    var message: Message = .{ .allocator = std.testing.allocator };
    defer message.deinit();
    try message.parse(bytes.items, .buffer);
    try std.testing.expect(message.used_fallback);
    try std.testing.expectEqual(@as(usize, 2000), message.value.array.items.len);
}
test "malformed messages free temporary storage" {
    inline for (.{ Mode.arena, Mode.buffer }) |mode| {
        var message: Message = .{ .allocator = std.testing.allocator };
        defer message.deinit();
        try std.testing.expectError(error.UnexpectedEndOfInput, message.parse("{\"a\":", mode));
    }
}

test "request buffer allocation failure leaves an empty owner" {
    var message: Message = .{ .allocator = std.testing.failing_allocator };
    defer message.deinit();
    try std.testing.expectError(error.OutOfMemory, message.parse("{}", .buffer));
    try std.testing.expect(message.buffer == null and message.parsed == null);
}

/// Adapter for std.json.Value's leaky parser. Its allocated-string tokens have
/// packet lifetime rather than individual allocation lifetime. Value's leaky
/// parser stores these views and never frees them; only the metadata arena is
/// released. Do not use this adapter with parsers that free individual tokens.
const InPlaceTokens = struct {
    scanner: std.json.Scanner,
    bytes: []u8,
    pub const NextError = std.json.Scanner.NextError;
    pub const PeekError = std.json.Scanner.PeekError;
    pub const AllocError = std.json.Scanner.AllocError || NextError;
    pub fn next(self: *InPlaceTokens) NextError!std.json.Token {
        return self.scanner.next();
    }
    pub fn nextAllocMax(self: *InPlaceTokens, allocator: std.mem.Allocator, when: std.json.AllocWhen, max_len: usize) AllocError!std.json.Token {
        const kind = try self.scanner.peekNextTokenType();
        if (kind != .string) return self.scanner.nextAllocMax(allocator, when, max_len);
        // peek leaves cursor at the opening quote.
        std.debug.assert(self.bytes[self.scanner.cursor] == '"');
        const start = self.scanner.cursor + 1;
        var written: usize = start;
        var token = try self.scanner.next();
        // No escapes: borrow the validated span without even a same-buffer copy.
        if (token == .string) {
            if (token.string.len > max_len) return error.ValueTooLong;
            return .{ .allocated_string = @constCast(token.string) };
        }
        while (true) {
            const part: []const u8 = switch (token) {
                .string, .partial_string => |v| v,
                .partial_string_escaped_1 => &token.partial_string_escaped_1,
                .partial_string_escaped_2 => &token.partial_string_escaped_2,
                .partial_string_escaped_3 => &token.partial_string_escaped_3,
                .partial_string_escaped_4 => &token.partial_string_escaped_4,
                else => unreachable,
            };
            if (part.len > max_len - (written - start)) return error.ValueTooLong;
            std.debug.assert(written + part.len <= self.scanner.cursor);
            // Forward copy supports overlap: decoded bytes never overtake input.
            for (part) |byte| {
                self.bytes[written] = byte;
                written += 1;
            }
            if (token == .string) return .{ .allocated_string = self.bytes[start..written] };
            token = try self.scanner.next();
        }
    }
};

test "in-place strings match standard JSON across escapes and truncations" {
    const samples = [_][]const u8{
        "{\"text\":\"a\\n\\uD83D\\uDE00\\t\\r\\b\\f\\\\\\/\\\"z\",\"list\":[true,null,-12.5e2]}",
        "[\"\",\"plain\",\"😀\",\"\\u0000\\u007f\\u0080\\u07ff\\u0800\\uffff\",{},[]]",
        "{\"\\u0061\":1,\"a\":2}",
        "\"\\uD800\"",
        "\"\\uDC00\"",
        "\"\\x\"",
        "\"\xff\"",
        "0 1",
        "{\"a\":}",
    };
    for (samples) |sample| {
        for (0..sample.len + 1) |end| {
            const bytes = try std.testing.allocator.dupe(u8, sample[0..end]);
            defer std.testing.allocator.free(bytes);
            var message: Message = .{ .allocator = std.testing.allocator };
            defer message.deinit();
            const reference = std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample[0..end], .{}) catch |expected| {
                if (message.parseInPlace(bytes)) |_| return error.ExpectedParseFailure else |actual| try std.testing.expectEqualStrings(@errorName(expected), @errorName(actual));
                continue;
            };
            defer reference.deinit();
            try message.parseInPlace(bytes);
            const a = try std.json.Stringify.valueAlloc(std.testing.allocator, reference.value, .{});
            defer std.testing.allocator.free(a);
            const b = try std.json.Stringify.valueAlloc(std.testing.allocator, message.value, .{});
            defer std.testing.allocator.free(b);
            try std.testing.expectEqualStrings(a, b);
        }
    }
}

fn inplaceAllocationCheck(allocator: std.mem.Allocator) !void {
    const input = "{\"text\":\"a\\n\\uD83D\\uDE00\",\"items\":[1,2,{},[true,false,null]],\"uri\":\"untitled:test\"}";
    var bytes: [input.len]u8 = undefined;
    @memcpy(&bytes, input);
    var message: Message = .{ .allocator = allocator };
    defer message.deinit();
    try message.parseInPlace(&bytes);
}
test "in-place metadata allocation failures release all owners" {
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), inplaceAllocationCheck, .{});
}

test "in-place arbitrary ASCII strings match standard encoder" {
    var text: [128]u8 = undefined;
    for (&text, 0..) |*byte, i| byte.* = @intCast(i);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .text = text[0..] }, .{});
    defer std.testing.allocator.free(encoded);
    var message: Message = .{ .allocator = std.testing.allocator };
    defer message.deinit();
    try message.parseInPlace(encoded);
    try std.testing.expectEqualStrings(&text, message.value.object.get("text").?.string);
}
