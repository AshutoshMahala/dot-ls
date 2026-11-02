const std = @import("std");
const build_options = @import("build_options");
const app = @import("app.zig");
pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer if (build_options.allocator_kind == .debug) std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = switch (build_options.allocator_kind) {
        .page => std.heap.page_allocator,
        .smp => std.heap.smp_allocator,
        .debug => debug_allocator.allocator(),
    };
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "--version"))) {
        var buffer: [1024]u8 = undefined;
        var out = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
        try out.interface.writeAll(if (std.mem.eql(u8, args[1], "--version")) "dot-ls " ++ app.server_version ++ "\n" else "Usage: dot-ls [lsp | --stdio | --version | --help]\nDevelopment checkpoint: DOT and HTML-label diagnostics, keyword completion and node references over stdio.\n");
        try out.interface.flush();
        return;
    }
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "lsp") and !std.mem.eql(u8, args[1], "--stdio"))) return error.InvalidArguments;
    // Small HTML cache allocations share pages. Return empty buckets on close.
    var html_allocator: std.heap.DebugAllocator(.{ .thread_safe = true, .stack_trace_frames = 0 }) = .{ .backing_allocator = allocator };
    defer std.debug.assert(html_allocator.deinit() == .ok);
    if (try app.run(init.io, allocator, html_allocator.allocator())) std.process.exit(1);
}
