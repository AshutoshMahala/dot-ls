//! Open-document data. The runtime server owns generation transitions and accounting.
const std = @import("std");
const snapshot = @import("snapshot.zig");
const actions = @import("../features/code_actions.zig");
const labels = @import("../features/labels.zig");
const Job = @import("job.zig").Job;
const requests = @import("requests.zig");
const limits = @import("limits.zig");
pub const Document = struct {
    outline_index: ?*snapshot.Outline = null,
    outline_done: bool = false,
    fixes: ?*snapshot.Fixes = null,
    fixes_done: bool = false,
    requests: requests.Queue = .{},
    index_pending: ?*Job = null,
    uri: []u8,
    version: i64,
    generation: u64,
    pending: ?*Job = null,
    references: ?*snapshot.References = null,
    completion: ?*snapshot.Completion = null,
    completion_done: bool = false,
    html_cache: ?*labels.Cache = null,
    pub fn setFixes(self: *Document, allocator: std.mem.Allocator, offers: []const actions.Fix, failed: bool, counter: *usize) void {
        std.debug.assert(offers.len <= limits.findings);
        if (self.fixes) |old| old.release(allocator);
        self.fixes = null;
        self.fixes_done = true;
        if (failed) return;
        const copy = allocator.dupe(actions.Fix, offers) catch return;
        self.fixes = snapshot.Fixes.create(allocator, copy, self.uri, self.version, self.generation, copy.len * @sizeOf(actions.Fix), counter, std.math.maxInt(usize)) catch {
            allocator.free(copy);
            return;
        };
    }
    pub fn dropHtmlCache(self: *Document, allocator: std.mem.Allocator) usize {
        const bytes = if (self.html_cache) |cache| cache.payload_bytes else 0;
        if (self.html_cache) |cache| cache.release(allocator);
        self.html_cache = null;
        return bytes;
    }
    /// All jobs, indexes and cache entries must first be retired by Server.
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        std.debug.assert(self.pending == null and self.index_pending == null);
        std.debug.assert(self.references == null and self.completion == null and self.outline_index == null);
        std.debug.assert(self.fixes == null and self.html_cache == null);
        self.requests.clear(allocator);
        allocator.free(self.uri);
    }
};

test "fix snapshot allocation failure leaves diagnostics publication independent" {
    var document: Document = .{ .uri = @constCast("untitled:test"), .version = 1, .generation = 1 };
    const offers = [_]actions.Fix{.{ .diagnostic = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .edit = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .kind = .delete, .preferred = true }};
    var counter: usize = 0;
    document.setFixes(std.testing.failing_allocator, &offers, false, &counter);
    try std.testing.expect(document.fixes_done);
    try std.testing.expect(document.fixes == null);
}
