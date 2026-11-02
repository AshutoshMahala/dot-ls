//! Owned pending requests. IDs are independent of JSON and protocol encoding.
const std = @import("std");
const text = @import("../text/types.zig");
const limits = @import("limits.zig");
pub const Id = union(enum) {
    null,
    integer: i64,
    string: []const u8,
    pub fn clone(self: Id, allocator: std.mem.Allocator) !Id {
        return if (self == .string) .{ .string = try allocator.dupe(u8, self.string) } else self;
    }
    pub fn deinit(self: Id, allocator: std.mem.Allocator) void {
        if (self == .string) allocator.free(self.string);
    }
    pub fn matchesCancellation(self: Id, other: Id) bool {
        return if (self == .string and other == .string) std.mem.eql(u8, self.string, other.string) else self == .integer and other == .integer and self.integer == other.integer;
    }
};
pub const Kind = enum { references, completion, hover, symbols };
pub const Request = struct { id: Id, point: text.Position, include: bool = false, kind: Kind = .references };
/// The containing document generation owns this whole queue. Invalidation clears
/// every request before that document can accept a new generation's work.
pub const Queue = struct {
    list: std.ArrayList(Request) = .empty,
    pub fn items(self: Queue) []const Request {
        return self.list.items;
    }
    pub fn canAppend(self: Queue, id: Id) bool {
        return self.list.items.len < limits.pending_requests and (id != .string or id.string.len <= limits.request_id);
    }
    pub fn append(self: *Queue, allocator: std.mem.Allocator, request: Request) !void {
        if (!self.canAppend(request.id)) return error.PendingLimit;
        var owned = request;
        owned.id = try request.id.clone(allocator);
        errdefer owned.id.deinit(allocator);
        try self.list.append(allocator, owned);
    }
    /// Transfers ownership of the removed ID to the caller.
    pub fn orderedRemove(self: *Queue, at: usize) Request {
        return self.list.orderedRemove(at);
    }
    pub fn clear(self: *Queue, allocator: std.mem.Allocator) void {
        for (self.list.items) |request| request.id.deinit(allocator);
        self.list.deinit(allocator);
        self.* = .{};
    }
};
pub const Failure = enum {
    modified,
    cancelled,
    reference_failed,
    reference_unavailable,
    outline_document,
    references_document,
    completion_document,
    actions_document,
    outline_unavailable,
    outline_incomplete,
    references_incomplete,
    completion_unavailable,
    completion_exceeded,
    outline_limit,
    references_limit,
    pending_limit,
    fixes_unavailable,
    diagnostics_not_ready,
    stale_diagnostics,
};
/// A synchronous borrowed handoff. The callback must not re-enter state or keep ID views.
pub const Observer = struct {
    context: *anyopaque,
    failure: *const fn (*anyopaque, Id, Failure) anyerror!void,
    pub fn fail(self: Observer, id: Id, reason: Failure) !void {
        try self.failure(self.context, id, reason);
    }
};

test "pending request IDs are owned and append failures release copies" {
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(allocator: std.mem.Allocator) !void {
            var queue: Queue = .{};
            defer queue.clear(allocator);
            var name = [_]u8{ 'a', 0, 'b' };
            try queue.append(allocator, .{ .id = .{ .string = &name }, .point = .{ .line = 1, .character = 2 } });
            name[0] = 'x';
            try std.testing.expectEqualStrings("a\x00b", queue.items()[0].id.string);
            const removed = queue.orderedRemove(0);
            defer removed.id.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), queue.items().len);
        }
    }.run, .{});
}

test "request limits and cancellation matching preserve queue contents" {
    var queue: Queue = .{};
    defer queue.clear(std.testing.allocator);
    const long_id: [limits.request_id + 1]u8 = @splat('x');
    try std.testing.expectError(error.PendingLimit, queue.append(std.testing.failing_allocator, .{ .id = .{ .string = &long_id }, .point = .{ .line = 0, .character = 0 } }));
    for (0..limits.pending_requests) |i| try queue.append(std.testing.allocator, .{ .id = .{ .integer = @intCast(i) }, .point = .{ .line = 0, .character = 0 } });
    try std.testing.expectError(error.PendingLimit, queue.append(std.testing.failing_allocator, .{ .id = .null, .point = .{ .line = 0, .character = 0 } }));
    try std.testing.expectEqual(@as(usize, limits.pending_requests), queue.items().len);
    try std.testing.expect((Id{ .integer = 7 }).matchesCancellation(.{ .integer = 7 }));
    try std.testing.expect(!(Id{ .integer = 7 }).matchesCancellation(.{ .string = "7" }));
    try std.testing.expect(!@as(Id, .null).matchesCancellation(.null));
}
