//! Parser-only control used in a temporary profiling build.
const std = @import("std");
const dot = @import("dot_parser");
const Cancellable = dot.Profile(.{ .policy = .{ .execution = .{ .cancellation = true }, .limits = .{ .max_nesting = 256 } } });
const Plain = dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 256 } } });
const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn poll(ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.flag.load(.acquire);
    }
};
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const text = try gpa.alloc(u8, 39_999_996);
    defer gpa.free(text);
    @memcpy(text[0..10], "digraph {\n");
    var offset: usize = 10;
    while (offset + 8 <= text.len - 2) : (offset += 8) @memcpy(text[offset..][0..8], "a -> b;\n");
    @memcpy(text[text.len - 2 ..], "}\n");
    var output_buffer: [4096]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    var cancel: Cancel = .{};
    for (0..6) |_| {
        var bag: dot.FixedDiagnosticBag(1000) = .{};
        var start = std.Io.Timestamp.now(init.io, .awake);
        const a = Cancellable.measure(gpa, text, bag.sink(), .{ .cancellation = .{ .context = &cancel, .is_requested = Cancel.poll } });
        const cancel_us = start.untilNow(init.io, .awake).toMicroseconds();
        bag = .{};
        start = std.Io.Timestamp.now(init.io, .awake);
        const b = Plain.measure(gpa, text, bag.sink(), .{});
        const plain_us = start.untilNow(init.io, .awake).toMicroseconds();
        if (a.outcome != .success or b.outcome != .success or bag.items().len != 0) return error.InvalidFixture;
        try out.interface.print("{{\"cancellable_us\":{d},\"plain_us\":{d},\"source_bytes\":{d},\"diagnostic_bag_bytes\":{d}}}\n", .{ cancel_us, plain_us, text.len, @sizeOf(@TypeOf(bag)) });
        try out.interface.flush();
    }
}
