//! One worker and the existing priority/yield loop. No protocol or server import.
const std = @import("std");
const Job = @import("job.zig").Job;
const requests = @import("requests.zig");
const Encoding = @import("../text/types.zig").Encoding;
const limits = @import("limits.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    advance: *const fn (*anyopaque, *Job, Encoding) anyerror!bool,
    failed: *const fn (*anyopaque, *Job) void,
    failures: *const fn (*anyopaque, *requests.Queue, requests.Failure) void,
};
pub fn start(state: anytype, callbacks: Callbacks) !std.Thread {
    return std.Thread.spawn(.{ .stack_size = limits.worker_stack }, run, .{ state, callbacks });
}
pub fn run(state: anytype, callbacks: Callbacks) void {
    while (true) {
        state.mutex.lockUncancelable(state.io);
        var job: ?*Job = null;
        while (job == null and !state.stopping) {
            job = select(state);
            if (job == null) state.condition.waitUncancelable(state.io, &state.mutex);
        }
        if (state.stopping) {
            state.mutex.unlock(state.io);
            return;
        }
        const current = job.?;
        state.active = current;
        const encoding = state.encoding;
        state.mutex.unlock(state.io);
        const again = callbacks.advance(callbacks.context, current, encoding) catch blk: {
            callbacks.failed(callbacks.context, current);
            break :blk false;
        };
        state.mutex.lockUncancelable(state.io);
        state.active = null;
        var retained = false;
        var failed: requests.Queue = .{};
        if (state.find(current.uri)) |i| if (state.documents.items[i].generation == current.generation and !state.stopping and !current.cancel.load(.acquire)) {
            const doc = &state.documents.items[i];
            if (again) {
                doc.index_pending = current;
                retained = true;
            } else if (doc.references == null) {
                failed = doc.requests;
                doc.requests = .{};
            }
        };
        if (!retained) {
            state.source_bytes -= current.allocation.len;
            current.destroy(state.allocator);
        }
        state.mutex.unlock(state.io);
        finishRequests(state.allocator, &failed, callbacks);
    }
}

/// Caller holds the state mutex. Intake priority also pauses delayed phases.
fn select(state: anytype) ?*Job {
    var job: ?*Job = null;
    // Pending syntax always takes priority over reference indexing.
    for (state.documents.items) |*doc| if (doc.pending) |pending| {
        job = pending;
        doc.pending = null;
        _ = state.syntax_pending.fetchSub(1, .release);
        break;
    };
    if (job == null and state.syntax_pending.load(.acquire) == 0) {
        // Delayed labels and completion both precede reference interning.
        for ([_]u8{ 0, 1, 2 }) |priority| {
            for (state.documents.items) |*doc| if (doc.index_pending) |pending| {
                if (@as(u8, switch (pending.phase) {
                    .context => 1,
                    .html => 0,
                    else => 2,
                }) != priority) continue;
                job = pending;
                doc.index_pending = null;
                break;
            };
            if (job != null) break;
        }
    }
    return job;
}

test "syntax then HTML then context then references; intake pauses delayed work" {
    const Document = @import("document.zig").Document;
    const Fake = struct {
        documents: struct { items: []Document },
        syntax_pending: std.atomic.Value(usize) = .init(0),
    };
    var syntax: Job = undefined;
    var html: Job = undefined;
    html.phase = .html;
    var context: Job = undefined;
    context.phase = .context;
    var index: Job = undefined;
    index.phase = .index;
    var docs = [_]Document{
        .{ .uri = @constCast("a"), .version = 1, .generation = 1, .index_pending = &index },
        .{ .uri = @constCast("b"), .version = 1, .generation = 1, .index_pending = &context },
        .{ .uri = @constCast("c"), .version = 1, .generation = 1, .index_pending = &html, .pending = &syntax },
    };
    var state: Fake = .{ .documents = .{ .items = &docs }, .syntax_pending = .init(2) };
    try std.testing.expect(select(&state) == &syntax);
    try std.testing.expectEqual(@as(usize, 1), state.syntax_pending.load(.acquire));
    try std.testing.expect(select(&state) == null);
    state.syntax_pending.store(0, .release);
    try std.testing.expect(select(&state) == &html);
    try std.testing.expect(select(&state) == &context);
    try std.testing.expect(select(&state) == &index);
    try std.testing.expect(select(&state) == null);
}

fn finishRequests(allocator: std.mem.Allocator, queue: *requests.Queue, callbacks: Callbacks) void {
    defer queue.clear(allocator);
    if (queue.items().len != 0) callbacks.failures(callbacks.context, queue, .reference_unavailable);
}

test "worker releases transferred queue capacity even when all requests were answered" {
    var queue: requests.Queue = .{};
    try queue.append(std.testing.allocator, .{ .id = .{ .integer = 1 }, .point = .{ .line = 0, .character = 0 } });
    const answered = queue.orderedRemove(0);
    answered.id.deinit(std.testing.allocator);
    var ctx: u8 = 0;
    finishRequests(std.testing.allocator, &queue, .{
        .context = &ctx,
        .advance = undefined,
        .failed = undefined,
        .failures = struct {
            fn unexpected(_: *anyopaque, _: *requests.Queue, _: requests.Failure) void {
                unreachable;
            }
        }.unexpected,
    });
    try std.testing.expectEqual(@as(usize, 0), queue.list.capacity);
}
