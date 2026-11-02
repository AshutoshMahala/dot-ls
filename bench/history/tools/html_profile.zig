//! Temporary-only core profiler; not linked into the server.
const std = @import("std");
const profile = @import("profile.zig");
const labels = @import("labels.zig");
const analysis = @import("analysis.zig");
fn never(_: ?*anyopaque) bool {
    return false;
}
pub fn main(init: std.process.Init) !void {
    profile.io = init.io;
    const gpa = std.heap.page_allocator;
    var cache_allocator: std.heap.DebugAllocator(.{ .thread_safe = true, .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(cache_allocator.deinit() == .ok);
    profile.cache_backing = cache_allocator.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    var previous: ?*labels.Cache = null;
    defer if (previous) |cache| cache.release(profile.allocator(.positions));
    const cancel: std.atomic.Value(bool) = .init(false);
    const waiting: std.atomic.Value(usize) = .init(0);
    for (args[1..], 0..) |path, number| {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, profile.allocator(.input), .limited(201 * 1024 * 1024));
        defer profile.allocator(.input).free(text);
        var collector: labels.Collector = .{ .allocator = profile.allocator(.parser), .source = text };
        defer collector.deinit();
        var scratch: analysis.Scratch = .{};
        var bag: analysis.Bag = .{};
        var started = profile.now();
        _ = analysis.runObserved(text, scratch.storage(), &bag, .{ .context = null, .is_requested = never }, null, &collector);
        profile.mark("dot_and_capture", profile.now() - started);
        var work = try labels.Work.init(profile.allocator(.positions));
        defer work.deinit();
        started = profile.now();
        if (!try work.advance(&collector, previous, &cancel, &waiting)) return error.UnexpectedYield;
        const elapsed = profile.now() - started;
        profile.mark("html_check_or_reuse", elapsed);
        const compact = @hasField(@TypeOf(collector.spans), "encoded");
        const count = if (compact) collector.spans.count else collector.spans.items.len;
        const used = if (compact) collector.spans.encoded.items.len else collector.spans.items.len * @sizeOf(@TypeOf(collector.spans.items[0]));
        const capacity = if (compact) collector.spans.encoded.capacity else collector.spans.capacity * @sizeOf(@TypeOf(collector.spans.items[0]));
        std.debug.print("{{\"sample\":{d},\"html_us\":{d},\"labels\":{d},\"span_bytes\":{d},\"span_capacity_bytes\":{d},\"checked\":{d},\"reused\":{d},\"cache_payload_bytes\":{d},\"cache_entries\":{d},\"diagnostics\":{d},\"incomplete\":{}}}\n", .{ number, @divTrunc(elapsed, 1000), count, used, capacity, work.checked, work.reused, work.cache.?.payload_bytes, work.cache.?.entries.count(), work.diagnostics.items.len, work.incomplete });
        if (previous) |cache| cache.release(profile.allocator(.positions));
        previous = work.cache;
        work.cache = null;
    }
}
