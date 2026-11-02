//! Used only in a temporary instrumented build. Not imported by the server.
const std = @import("std");
pub var io: std.Io = undefined;
pub const Category = enum { misc, input, json, snapshot, parser, response, positions };
const Stats = struct {
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(usize) = .init(0),
};
var stats: [7]Stats = @splat(.{});
var total: std.atomic.Value(usize) = .init(0);
var peak: std.atomic.Value(usize) = .init(0);
var contexts = [_]Category{ .misc, .input, .json, .snapshot, .parser, .response, .positions };
pub var json_used: std.atomic.Value(usize) = .init(0);
pub var backing: std.mem.Allocator = std.heap.page_allocator;
pub fn allocator(which: Category) std.mem.Allocator {
    return .{ .ptr = &contexts[@intFromEnum(which)], .vtable = &vtable };
}
fn category(ctx: *anyopaque) usize {
    const ptr: *Category = @ptrCast(@alignCast(ctx));
    return @intFromEnum(ptr.*);
}
fn raise(counter: *std.atomic.Value(usize), value: usize) void {
    var old = counter.load(.monotonic);
    while (value > old) {
        old = counter.cmpxchgWeak(old, value, .monotonic, .monotonic) orelse return;
    }
}
fn add(i: usize, n: usize) void {
    raise(&stats[i].peak, stats[i].live.fetchAdd(n, .monotonic) + n);
    raise(&peak, total.fetchAdd(n, .monotonic) + n);
}
fn subtract(i: usize, n: usize) void {
    _ = stats[i].live.fetchSub(n, .monotonic);
    _ = total.fetchSub(n, .monotonic);
}
fn allocation(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const p = backing.rawAlloc(n, alignment, ra) orelse return null;
    const i = category(ctx);
    add(i, n);
    _ = stats[i].allocations.fetchAdd(1, .monotonic);
    return p;
}
fn changed(ctx: *anyopaque, old: usize, new: usize) void {
    if (new >= old) add(category(ctx), new - old) else subtract(category(ctx), old - new);
}
fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
    if (!backing.rawResize(memory, alignment, n, ra)) return false;
    changed(ctx, memory.len, n);
    return true;
}
fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
    const p = backing.rawRemap(memory, alignment, n, ra) orelse return null;
    changed(ctx, memory.len, n);
    return p;
}
fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    backing.rawFree(memory, alignment, ra);
    subtract(category(ctx), memory.len);
}
const vtable: std.mem.Allocator.VTable = .{ .alloc = allocation, .resize = resize, .remap = remap, .free = free };
pub fn now() i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}
pub fn mark(stage: []const u8, elapsed: i96) void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.Writer.init(.stderr(), io, &buffer);
    out.interface.print("{{\"stage\":\"{s}\",\"us\":{d},\"total_peak_bytes\":{d},\"categories\":[", .{ stage, @divTrunc(elapsed, 1000), peak.load(.monotonic) }) catch return;
    inline for (contexts, 0..) |name, i| {
        out.interface.print("{s}{{\"name\":\"{s}\",\"live\":{d},\"peak\":{d},\"allocations\":{d}}}", .{ if (i == 0) "" else ",", @tagName(name), stats[i].live.load(.monotonic), stats[i].peak.load(.monotonic), stats[i].allocations.load(.monotonic) }) catch return;
    }
    out.interface.print("],\"json_used_bytes\":{d}}}\n", .{json_used.load(.monotonic)}) catch return;
    out.interface.flush() catch {};
    if (@import("pause.zig").enabled and (std.mem.eql(u8, stage, "body_read") or std.mem.eql(u8, stage, "json_decode") or std.mem.eql(u8, stage, "snapshot_copy") or std.mem.eql(u8, stage, "parser") or std.mem.eql(u8, stage, "json_cleanup") or std.mem.eql(u8, stage, "input_cleanup") or std.mem.eql(u8, stage, "job_cleanup") or std.mem.eql(u8, stage, "positions_ready"))) {
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }
}
