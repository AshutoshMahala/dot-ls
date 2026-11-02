#!/usr/bin/env python3
"""Build an instrumented temporary copy; production has no tracing hooks."""
import pathlib, shutil, sys, tempfile
project=pathlib.Path(__file__).resolve().parent.parent
source=pathlib.Path(sys.argv[1]).resolve() if len(sys.argv)>1 else project
root=pathlib.Path(tempfile.mkdtemp(prefix='dot-index-profile-',dir='/private/tmp'))
for name in ('src','vendor'):shutil.copytree(source/name,root/name)
for name in ('build.zig','build.zig.zon'):shutil.copy(source/name,root/name)
profile=(project/'tools/profile.zig').read_text()
profile=profile.replace('misc, input, json, snapshot, parser, response, positions','misc, source, names, decoded, occurrences, sort, entries')
profile=profile.replace('.misc, .input, .json, .snapshot, .parser, .response, .positions','.misc, .source, .names, .decoded, .occurrences, .sort, .entries')
(root/'src/profile.zig').write_text(profile)
(root/'src/pause.zig').write_text('pub const enabled = false;\n')
p=root/'src/references.zig';s=p.read_text();s=s.replace('const std =', 'const profile = @import("profile.zig");\nconst std =', 1)
for name in ('names','occurrences'):
 s=s.replace(f'self.{name}.deinit(self.allocator)',f'self.{name}.deinit(profile.allocator(.{name}))')
 s=s.replace(f'self.{name}.getOrPut(self.allocator,',f'self.{name}.getOrPut(profile.allocator(.{name}),')
 s=s.replace(f'self.{name}.append(self.allocator,',f'self.{name}.append(profile.allocator(.{name}),')
s=s.replace('self.names.getOrPutContext(self.allocator,', 'self.names.getOrPutContext(profile.allocator(.names),')
s=s.replace('self.allocator.alloc(u8, raw.len)', 'profile.allocator(.decoded).alloc(u8, raw.len)').replace('if (temporary) |bytes| self.allocator.free(bytes)', 'if (temporary) |bytes| profile.allocator(.decoded).free(bytes)')
s=s.replace('std.heap.ArenaAllocator.init(allocator)', 'std.heap.ArenaAllocator.init(profile.allocator(.decoded))')
s=s.replace('self.allocator.alloc(Occurrence,', 'profile.allocator(.sort).alloc(Occurrence,').replace('self.allocator.free(scratch)', 'profile.allocator(.sort).free(scratch)')
s=s.replace('self.allocator.alloc(Entry,', 'profile.allocator(.entries).alloc(Entry,').replace('self.allocator.free(entries)', 'profile.allocator(.entries).free(entries)')
s=s.replace('        const spans = self.occurrences.items;', '        const t_sort = profile.now();\n        const spans = self.occurrences.items;')
s=s.replace('        const entries = try', '        profile.mark("sort", profile.now()-t_sort);\n        var t_convert = profile.now();\n        const entries = try',1)
s=s.replace('        return .{ .entries = entries };','        profile.mark("conversion", profile.now()-t_convert);\n        return .{ .entries = entries };')
if 'var ends: std.ArrayList(End)' in s:
 s=s.replace('        var ends: std.ArrayList(End)', '        profile.mark("interning", profile.now()-t_convert);\n        t_convert = profile.now();\n        var ends: std.ArrayList(End)')
 s=s.replace('ends.append(self.allocator,', 'ends.append(profile.allocator(.entries),').replace('ends.deinit(self.allocator)', 'ends.deinit(profile.allocator(.entries))').replace('ends.toOwnedSlice(self.allocator)', 'ends.toOwnedSlice(profile.allocator(.entries))')
 s=s.replace('        return .{ .entries = entries, .ends =', '        profile.mark("conversion", profile.now()-t_convert);\n        return .{ .entries = entries, .ends =')
p.write_text(s)
shutil.copy(project/'tools/index_profile.zig',root/'src/index_profile.zig')
p=root/'build.zig';s=p.read_text();s=s.replace('    b.installArtifact(exe);','''    b.installArtifact(exe);
    const bench = b.addExecutable(.{ .name = "index-profile", .root_module = b.createModule(.{ .root_source_file = b.path("src/index_profile.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "dot_parser", .module = parser }} }) });
    b.step("profile-index", "Build temporary stage profiler").dependOn(&b.addInstallArtifact(bench, .{}).step);''');p.write_text(s)
print(root)
