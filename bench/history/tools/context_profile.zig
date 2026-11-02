const std = @import("std");
const profile = @import("profile.zig");
const context = @import("completion_context.zig");
pub fn main(init: std.process.Init) !void {
    profile.io = init.io;
    const gpa = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], profile.allocator(.input), .limited(201 * 1024 * 1024));
    defer profile.allocator(.input).free(text);
    const cancel: std.atomic.Value(bool) = .init(false);
    for (0..5) |_| {
        const start = profile.now();
        var index = try context.build(profile.allocator(.positions), text, .utf16, &cancel, null);
        const elapsed = profile.now() - start;
        profile.mark("context", elapsed);
        std.debug.print("{{\"us\":{d},\"events\":{d},\"anchors\":{d},\"lines\":{d},\"unicode\":{d},\"total\":{d}}}\n", .{ @divTrunc(elapsed, 1000), index.events.len, index.anchors.len * 12, index.lines.len * 4, index.unicode.len * 8, index.bytes() });
        index.deinit(profile.allocator(.positions));
    }
}
