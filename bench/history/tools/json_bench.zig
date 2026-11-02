const std = @import("std");
const json = @import("json_message");
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const prefix = "{\"text\":\"digraph {\\n";
    const suffix = "}\\n\"}";
    const count = 4_999_998;
    const bytes = try allocator.alloc(u8, prefix.len + count * 9 + suffix.len);
    defer allocator.free(bytes);
    @memcpy(bytes[0..prefix.len], prefix);
    for (0..count) |i| @memcpy(bytes[prefix.len + i * 9 ..][0..9], "a -> b;\\n");
    @memcpy(bytes[bytes.len - suffix.len ..], suffix);
    var buffer: [2048]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    inline for (.{ json.Mode.arena, json.Mode.buffer }) |mode| {
        var message: json.Message = .{ .allocator = allocator };
        const start = std.Io.Timestamp.now(init.io, .awake);
        try message.parse(bytes, mode);
        const us = start.untilNow(init.io, .awake).toMicroseconds();
        try out.interface.print("mode={s} us={d} fallback={any} fixed_used={d} fixed_capacity={d} arena_capacity={d}\n", .{ @tagName(mode), us, message.used_fallback, if (message.buffer != null) message.fixed.end_index else 0, if (message.buffer) |b| b.len else 0, if (message.parsed) |p| p.arena.queryCapacity() else 0 });
        try out.interface.flush();
        message.deinit();
    }
}
