#!/usr/bin/env python3
"""Build a disposable profiler with cache-hit counts and allocator categories."""
import pathlib,shutil,tempfile
project=pathlib.Path(__file__).resolve().parent.parent
root=pathlib.Path(tempfile.mkdtemp(prefix='dot-html-profile-',dir='/private/tmp'))
for name in ('src','vendor'):shutil.copytree(project/name,root/name)
for name in ('build.zig','build.zig.zon'):shutil.copy(project/name,root/name)
for name in ('html_profile.zig','profile.zig'):shutil.copy(project/'tools'/name,root/'src'/name)
p=root/'src/profile.zig';s=p.read_text().replace('pub var backing: std.mem.Allocator = std.heap.page_allocator;', 'pub var backing: std.mem.Allocator = std.heap.page_allocator;\npub var cache_backing: std.mem.Allocator = std.heap.page_allocator;\nfn backingFor(ctx: *anyopaque) std.mem.Allocator { return if (category(ctx) == @intFromEnum(Category.positions)) cache_backing else backing; }').replace('backing.raw', 'backingFor(ctx).raw');p.write_text(s)
(root/'src/pause.zig').write_text('pub const enabled = false;\n')
p=root/'build.zig';s=p.read_text().replace('    b.installArtifact(exe);','''    b.installArtifact(exe);
    const bench = b.addExecutable(.{ .name = "html-profile", .root_module = b.createModule(.{ .root_source_file = b.path("src/html_profile.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "dot_parser", .module = parser }, .{ .name = "markup_parser", .module = markup }} }) });
    b.step("profile-html", "Build HTML profiler").dependOn(&b.addInstallArtifact(bench, .{}).step);''');p.write_text(s)
print(root)
