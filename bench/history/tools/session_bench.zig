//! Matched retained-session tests. Source and fixed pools are allocated once.
const std = @import("std");
const dot = @import("dot_parser");
const count = 4_999_998;
const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn poll(ctx: ?*anyopaque) bool {
        // Context is the caller-owned Cancel value alive for the entire session.
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.flag.load(.acquire);
    }
};
const Sample = struct { us: i64, calls: usize, credits: usize, session_bytes: usize };
fn run(comptime scanner: dot.ScannerBackend, comptime metered: bool, comptime hook: bool, budget: usize, io: std.Io, source: []const u8, storage: dot.DocumentStorage, cancel: *Cancel) !Sample {
    const Session = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = metered, .cancellation = hook }, .limits = .{ .max_nesting = 256 } } }).Session;
    var bag: dot.FixedDiagnosticBag(1000) = .{};
    var session = Session.init(source, .{ .document = storage }, bag.sink(), if (hook) .{ .cancellation = .{ .context = cancel, .is_requested = Cancel.poll } } else .{});
    defer session.deinit();
    var calls: usize = 0;
    var credits: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    const result = if (metered) blk: {
        while (true) {
            const progress = session.advance(budget);
            calls += 1;
            credits += progress.work_used;
            if (progress.outcome != null) break;
        }
        break :blk session.result().?;
    } else session.run();
    const us = start.untilNow(io, .awake).toMicroseconds();
    if (result.outcome != .success or result.document.?.statementCount() != count or bag.items().len != 0) return error.InvalidResult;
    return .{ .us = us, .calls = calls, .credits = credits, .session_bytes = @sizeOf(Session) };
}
fn dispatch(comptime scanner: dot.ScannerBackend, mode: usize, io: std.Io, text: []const u8, storage: dot.DocumentStorage, cancel: *Cancel) !Sample {
    return switch (mode) {
        0 => run(scanner, false, false, 0, io, text, storage, cancel),
        1 => run(scanner, false, true, 0, io, text, storage, cancel),
        2 => run(scanner, true, false, 256, io, text, storage, cancel),
        3 => run(scanner, true, true, 256, io, text, storage, cancel),
        4 => run(scanner, true, false, 4096, io, text, storage, cancel),
        5 => run(scanner, true, true, 4096, io, text, storage, cancel),
        6 => run(scanner, true, false, 65536, io, text, storage, cancel),
        7 => run(scanner, true, true, 65536, io, text, storage, cancel),
        else => unreachable,
    };
}
fn quanta(comptime scanner: dot.ScannerBackend, budget: usize, io: std.Io, text: []const u8, storage: dot.DocumentStorage, writer: *std.Io.Writer) !void {
    const Session = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .limits = .{ .max_nesting = 256 } } }).Session;
    var bag: dot.FixedDiagnosticBag(1000) = .{};
    var session = Session.init(text, .{ .document = storage }, bag.sink(), .{});
    defer session.deinit();
    var ns: [256]u64 = undefined;
    var frontier: usize = 0;
    for (&ns) |*value| {
        const start = std.Io.Timestamp.now(io, .awake);
        const progress = session.advance(budget);
        value.* = @intCast(start.untilNow(io, .awake).nanoseconds);
        if (progress.outcome != null or progress.work_used > budget) return error.BadBudget;
        frontier = progress.source_frontier;
    }
    // Cancelling a paused session is terminal and must expose no document.
    const start = std.Io.Timestamp.now(io, .awake);
    const stopped = session.cancel();
    const cancel_ns = start.untilNow(io, .awake).nanoseconds;
    if (stopped.outcome != .cancelled or stopped.document != null) return error.BadCancellation;
    std.mem.sort(u64, &ns, {}, std.sort.asc(u64));
    try writer.print("{{\"kind\":\"quanta\",\"scanner\":\"{s}\",\"budget\":{d},\"p50_ns\":{d},\"p95_ns\":{d},\"max_ns\":{d},\"cancel_ns\":{d},\"source_frontier\":{d}}}\n", .{ @tagName(scanner), budget, ns[128], ns[243], ns[255], cancel_ns, frontier });
    try writer.flush();
}
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const start = std.Io.Timestamp.now(init.io, .awake);
    const text = try gpa.alloc(u8, 12 + count * 8);
    defer gpa.free(text);
    @memcpy(text[0..10], "digraph {\n");
    for (0..count) |i| @memcpy(text[10 + i * 8 ..][0..8], "a -> b;\n");
    @memcpy(text[text.len - 2 ..], "}\n");
    const ids = try gpa.alloc(dot.StatementId, count);
    defer gpa.free(ids);
    const edges = try gpa.alloc(dot.EdgeStatement, count);
    defer gpa.free(edges);
    const storage: dot.DocumentStorage = .{ .statement_ids = ids, .edges = edges };
    const setup_us = start.untilNow(init.io, .awake).toMicroseconds();
    var output_buffer: [4096]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const pool_bytes = ids.len * @sizeOf(dot.StatementId) + edges.len * @sizeOf(dot.EdgeStatement);
    try out.interface.print("{{\"kind\":\"memory\",\"source_bytes\":{d},\"pool_bytes\":{d},\"statement_bytes\":{d},\"edge_bytes\":{d},\"bag_bytes\":{d},\"setup_us\":{d}}}\n", .{ text.len, pool_bytes, @sizeOf(dot.StatementId), @sizeOf(dot.EdgeStatement), @sizeOf(dot.FixedDiagnosticBag(1000)), setup_us });
    try out.interface.flush();
    var cancel: Cancel = .{};
    // All modes get two warm-up rounds and three measured rounds. Rotate order.
    for (0..5) |round| {
        for (0..16) |shift| {
            const variant = (round * 3 + shift) % 16;
            const mode = variant % 8;
            const sample = if (variant < 8) try dispatch(.scalar, mode, init.io, text, storage, &cancel) else try dispatch(.block, mode, init.io, text, storage, &cancel);
            if (round >= 2) {
                const budget: usize = switch (mode) {
                    0, 1 => 0,
                    2, 3 => 256,
                    4, 5 => 4096,
                    6, 7 => 65536,
                    else => unreachable,
                };
                try out.interface.print("{{\"kind\":\"throughput\",\"scanner\":\"{s}\",\"metered\":{s},\"hook\":{s},\"budget\":{d},\"round\":{d},\"us\":{d},\"calls\":{d},\"credits\":{d},\"session_bytes\":{d}}}\n", .{ if (variant < 8) "scalar" else "block", if (mode >= 2) "true" else "false", if (mode % 2 == 1) "true" else "false", budget, round - 2, sample.us, sample.calls, sample.credits, sample.session_bytes });
                try out.interface.flush();
            }
        }
    }
    inline for (.{ 256, 4096, 65536 }) |budget| {
        try quanta(.scalar, budget, init.io, text, storage, &out.interface);
        try quanta(.block, budget, init.io, text, storage, &out.interface);
    }
}
