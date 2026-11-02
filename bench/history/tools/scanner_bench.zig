//! Compare scanners on identical source, with and without cancellation.
const std = @import("std");
const dot = @import("dot_parser");
const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn poll(ctx: ?*anyopaque) bool {
        // Context is the live Cancel value passed to measure for this call.
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.flag.load(.acquire);
    }
};
fn measure(comptime scanner: dot.ScannerBackend, comptime cancellable: bool, io: std.Io, gpa: std.mem.Allocator, text: []const u8, cancel: *Cancel) !i64 {
    const Parser = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .cancellation = cancellable }, .limits = .{ .max_nesting = 256 } } });
    var bag: dot.FixedDiagnosticBag(1000) = .{};
    const start = std.Io.Timestamp.now(io, .awake);
    const result = Parser.measure(gpa, text, bag.sink(), if (cancellable) .{ .cancellation = .{ .context = cancel, .is_requested = Cancel.poll } } else .{});
    const us = start.untilNow(io, .awake).toMicroseconds();
    if (result.outcome != .success or bag.items().len != 0) return error.InvalidFixture;
    return us;
}
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const text = try gpa.alloc(u8, 39_999_996);
    defer gpa.free(text);
    var output_buffer: [4096]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    var cancel: Cancel = .{};
    for (0..2) |fixture| {
        @memcpy(text[0..10], "digraph {\n");
        if (fixture == 0) {
            var offset: usize = 10;
            while (offset + 8 <= text.len - 2) : (offset += 8) @memcpy(text[offset..][0..8], "a -> b;\n");
        } else {
            @memcpy(text[10..14], "/*xx");
            @memset(text[14 .. text.len - 4], 'x');
            @memcpy(text[text.len - 4 .. text.len - 2], "*/");
        }
        @memcpy(text[text.len - 2 ..], "}\n");
        // Two warm-up rounds. Rotate order across eight measured rounds.
        for (0..10) |round| {
            for (0..4) |shift| {
                const variant = (round + shift) % 4;
                const us = switch (variant) {
                    0 => try measure(.scalar, false, init.io, gpa, text, &cancel),
                    1 => try measure(.scalar, true, init.io, gpa, text, &cancel),
                    2 => try measure(.block, false, init.io, gpa, text, &cancel),
                    3 => try measure(.block, true, init.io, gpa, text, &cancel),
                    else => unreachable,
                };
                if (round >= 2) {
                    try out.interface.print("{{\"fixture\":\"{s}\",\"scanner\":\"{s}\",\"cancellation\":{s},\"round\":{d},\"us\":{d},\"bytes\":{d}}}\n", .{ if (fixture == 0) "edges" else "long_comment", if (variant < 2) "scalar" else "block", if (variant % 2 == 1) "true" else "false", round - 2, us, text.len });
                    try out.interface.flush();
                }
            }
        }
    }
}
