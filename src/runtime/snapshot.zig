//! Immutable feature ownership. Retain/release and admission require the state
//! mutex. A reader may query value and metadata outside it until release.
//! Each handle owns one feature allocation; no source or other feature is pinned.
const std = @import("std");
const context = @import("../features/completion_context.zig");
const references = @import("../features/references.zig");
const outline = @import("../features/outline.zig");
const actions = @import("../features/code_actions.zig");
pub const Completion = Lease(context.Index);
pub const References = Lease(references.Index);
pub const Outline = Lease(outline.Index);
pub const Fixes = Lease([]actions.Fix);
pub fn Lease(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,
        uri: []const u8,
        version: i64,
        generation: u64,
        readers: usize = 1,
        charged: usize,
        counter: *usize,
        /// Takes value only on success. Header and URI share one allocation.
        pub fn create(allocator: std.mem.Allocator, value: T, uri: []const u8, version: i64, generation: u64, payload: usize, counter: *usize, limit: usize) !*Self {
            const charged = @sizeOf(Self) + uri.len + payload;
            if (counter.* > limit or charged > limit - counter.*) return error.SnapshotLimit;
            const memory = try allocator.alignedAlloc(u8, .of(Self), @sizeOf(Self) + uri.len);
            const self: *Self = @ptrCast(memory.ptr);
            const key = memory[@sizeOf(Self)..];
            @memcpy(key, uri);
            self.* = .{ .value = value, .uri = key, .version = version, .generation = generation, .charged = charged, .counter = counter };
            counter.* += charged;
            return self;
        }
        pub fn retain(self: *Self) *Self {
            std.debug.assert(self.readers > 0);
            self.readers += 1;
            return self;
        }
        pub fn release(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.readers > 0);
            self.readers -= 1;
            if (self.readers != 0) return;
            if (T == []actions.Fix) allocator.free(self.value) else self.value.deinit(allocator);
            self.counter.* -= self.charged;
            const memory: [*]align(@alignOf(Self)) u8 = @ptrCast(self);
            allocator.free(memory[0 .. @sizeOf(Self) + self.uri.len]);
        }
    };
}

test "retired feature stays charged and readable until the last reply releases it" {
    const a = std.testing.allocator;
    var charged: usize = 0;
    const entries = try a.alloc(references.Entry, 1);
    entries[0] = .{ .line = 0, .character = 2, .length = 1, .symbol = 7 };
    const index: references.Index = .{ .entries = entries };
    const published = try References.create(a, index, "untitled:old", 3, 9, index.bytes(), &charged, 1024);
    const reply = published.retain();
    const bytes = charged;
    published.release(a); // edit or close retires the document's owner
    try std.testing.expectEqual(bytes, charged);
    try std.testing.expectEqualStrings("untitled:old", reply.uri);
    try std.testing.expectEqual(@as(?u32, 7), reply.value.symbolAt(.{ .line = 0, .character = 2 }));
    try std.testing.expectError(error.SnapshotLimit, References.create(a, .{}, "new", 4, 10, 0, &charged, bytes));
    reply.release(a);
    try std.testing.expectEqual(@as(usize, 0), charged);
}

test "snapshot allocation failure leaves the input owned by the caller" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var charged: usize = 0;
            var value: references.Index = .{ .entries = try a.alloc(references.Entry, 1) };
            errdefer value.deinit(a);
            const lease = try References.create(a, value, "uri", 1, 1, value.bytes(), &charged, 1024);
            lease.release(a);
            try std.testing.expectEqual(@as(usize, 0), charged);
        }
    }.run, .{});
}
