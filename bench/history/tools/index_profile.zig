const std = @import("std");
const analysis = @import("analysis.zig");
const references = @import("references.zig");
const profile = @import("profile.zig");
fn never(_: ?*anyopaque) bool { return false; }
pub fn main(init: std.process.Init) !void {
    profile.io = init.io;
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], profile.allocator(.source), .limited(201*1024*1024));
    defer profile.allocator(.source).free(text);
    var cancel: std.atomic.Value(bool) = .init(false);
    for (0..5) |_| {
        var scratch: analysis.Scratch = .{};
        var bag: analysis.Bag = .{};
        var t = profile.now();
        const plain = analysis.run(text, scratch.storage(), &bag, .{ .context = null, .is_requested = never });
        profile.mark("parser_only", profile.now()-t);
        if (plain.outcome != .success) return error.InvalidFixture;
        var builder = references.Builder.init(allocator,text,&cancel);
        t = profile.now();
        const result = analysis.runIndexed(text,scratch.storage(),&bag,.{ .context = null, .is_requested = never },&builder);
        profile.mark("collection", profile.now()-t);
        if (result.outcome != .success) return error.InvalidFixture;
        t=profile.now();
        var index = try builder.finish(.utf16);
        profile.mark("finish",profile.now()-t);
        builder.deinit();
        profile.mark("retained",0);
        index.deinit(profile.allocator(.entries));
        profile.mark("released",0);
    }
}
