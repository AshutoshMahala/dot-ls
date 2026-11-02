from pathlib import Path
import shutil, tempfile
root=Path(tempfile.mkdtemp(prefix='dot-context-profile-',dir='/private/tmp'))
for name in ('src','vendor'):shutil.copytree(Path(name),root/name,dirs_exist_ok=True)
for name in ('build.zig','build.zig.zon'):shutil.copy(name,root/name)
shutil.copy('tools/context_profile.zig',root/'src/context_profile.zig')
shutil.copy('tools/profile.zig',root/'src/profile.zig')
(root/'src/pause.zig').write_text('pub const enabled = false;\n')
p=root/'src/completion_context.zig';s=p.read_text().replace('    try builder.scan();', '    var started = @import("profile.zig").now();\n    try builder.scan();\n    @import("profile.zig").mark("lex_regions", @import("profile.zig").now()-started);\n    started = @import("profile.zig").now();').replace('    try builder.coordinates(encoding);', '    try builder.coordinates(encoding);\n    @import("profile.zig").mark("coordinates", @import("profile.zig").now()-started);');p.write_text(s)
p=root/'build.zig';s=p.read_text().replace('    b.installArtifact(exe);','''    b.installArtifact(exe);
    const bench = b.addExecutable(.{ .name = "context-profile", .root_module = b.createModule(.{ .root_source_file = b.path("src/context_profile.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "dot_parser", .module = parser }} }) });
    b.step("profile-context", "Build context profiler").dependOn(&b.addInstallArtifact(bench, .{}).step);''');p.write_text(s)
print(root)
