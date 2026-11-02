//! Job owns its immutable source allocation after preparation commits.
const std = @import("std");
const pipeline = @import("../analysis/pipeline.zig");
const labels = @import("../features/labels.zig");
const references = @import("../features/references.zig");
const outline = @import("../features/outline.zig");
const actions = @import("../features/code_actions.zig");
pub const Job = struct {
    text: []const u8,
    // Exact allocation to free: either a source copy or the transferred packet.
    allocation: []u8,
    uri: []u8,
    version: i64,
    generation: u64,
    phase: enum { syntax, context, html, index } = .syntax,
    want_references: bool = false,
    labels: ?labels.Collector = null,
    html: ?labels.Work = null,
    html_ready: bool = false,
    // Completed HTML findings remain alive through the application encoder.
    phase_result: ?pipeline.Html = null,
    previous_html: ?*labels.Cache = null,
    wording: ?std.heap.ArenaAllocator = null,
    diagnostics: std.ArrayList(@import("../analysis/diagnostic_text.zig").Finding) = .empty,
    fixes: std.ArrayList(actions.Fix) = .empty,
    fixes_failed: bool = false,
    outline_builder: ?outline.Builder = null,
    builder: ?references.Builder = null,
    cancel: std.atomic.Value(bool) = .init(false),
    pub fn poll(ctx: ?*anyopaque) bool {
        // The context is the live Job passed to measure; the worker owns its lifetime.
        const self: *Job = @ptrCast(@alignCast(ctx.?));
        return self.cancel.load(.acquire);
    }
    pub fn releaseResult(self: *Job, allocator: std.mem.Allocator) void {
        if (self.phase_result) |*result| result.deinit(allocator);
        self.phase_result = null;
    }
    pub fn destroy(self: *Job, allocator: std.mem.Allocator) void {
        self.releaseResult(allocator);
        if (self.outline_builder) |*builder| builder.deinit();
        if (self.builder) |*builder| builder.deinit();
        if (self.labels) |*collector| collector.deinit();
        if (self.html) |*work| work.deinit();
        if (self.previous_html) |cache| cache.release(allocator);
        self.diagnostics.deinit(allocator);
        self.fixes.deinit(allocator);
        if (self.wording) |*arena| arena.deinit();
        allocator.free(self.allocation);
        allocator.free(self.uri);
        allocator.destroy(self);
    }
};

/// The caller owns packet until update reports .transferred. With packet=null,
/// preparation makes the same single source copy as the previous intake path.
pub const Input = struct { text: []const u8, packet: ?[]u8 = null };
pub const Prepared = struct {
    job: ?*Job,
    transfers_packet: bool,
    pub fn init(allocator: std.mem.Allocator, input: Input, uri: []const u8, version: i64, generation: u64) !Prepared {
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        const source = if (input.packet != null) input.text else try allocator.dupe(u8, input.text);
        errdefer if (input.packet == null) allocator.free(source);
        const owned_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned_uri);
        job.* = .{ .text = source, .allocation = input.packet orelse @constCast(source), .uri = owned_uri, .version = version, .generation = generation };
        return .{ .job = job, .transfers_packet = input.packet != null };
    }
    pub fn commit(self: *Prepared) *Job {
        const job = self.job.?;
        self.job = null;
        return job;
    }
    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        if (self.job) |job| {
            allocator.free(job.uri);
            if (!self.transfers_packet) allocator.free(job.allocation);
            allocator.destroy(job);
            self.job = null;
        }
    }
};

test "copied job preparation rolls back every allocation and commits once" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var prepared = try Prepared.init(allocator, .{ .text = "graph {}" }, "untitled:copy", 1, 3);
            defer prepared.deinit(allocator);
            const job = prepared.commit();
            defer job.destroy(allocator);
            try std.testing.expectEqualStrings("graph {}", job.text);
            try std.testing.expectEqual(@as(u64, 3), job.generation);
            try std.testing.expect(prepared.job == null);
        }
    }.run, .{});
}

test "packet preparation leaves caller ownership intact until commit" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const packet = try std.testing.allocator.dupe(u8, "---graph {}---");
            defer std.testing.allocator.free(packet);
            var prepared = try Prepared.init(allocator, .{ .text = packet[3..11], .packet = packet }, "untitled:packet", 2, 4);
            prepared.deinit(allocator);
            // A prepared-but-unaccepted packet must still belong to the caller.
            try std.testing.expectEqualStrings("---graph {}---", packet);
        }
    }.run, .{});
    const allocator = std.testing.allocator;
    const packet = try allocator.dupe(u8, "---graph {}---");
    var prepared = try Prepared.init(allocator, .{ .text = packet[3..11], .packet = packet }, "untitled:packet", 2, 4);
    defer prepared.deinit(allocator);
    const job = prepared.commit();
    defer job.destroy(allocator);
    try std.testing.expect(job.allocation.ptr == packet.ptr);
    try std.testing.expect(job.text.ptr == packet[3..].ptr);
    try std.testing.expectEqual(@as(usize, 14), job.allocation.len);
}
