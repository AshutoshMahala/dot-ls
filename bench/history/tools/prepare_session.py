#!/usr/bin/env python3
"""Build a self-contained temporary session benchmark source tree."""
import pathlib, tempfile, shutil
project=pathlib.Path(__file__).resolve().parent.parent
root=pathlib.Path(tempfile.mkdtemp(prefix='dotls-session-',dir='/private/tmp'))
for name in ('src','vendor'):shutil.copytree(project/name,root/name)
for name in ('build.zig','build.zig.zon'):shutil.copy(project/name,root/name)
shutil.copy(project/'tools/session_bench.zig',root/'src/session_bench.zig')
p=root/'build.zig'
s=p.read_text().replace('    b.installArtifact(exe);','''    b.installArtifact(exe);
    const probe = b.addExecutable(.{ .name = "session-profile", .root_module = b.createModule(.{
        .root_source_file = b.path("src/session_bench.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "dot_parser", .module = parser }},
    }) });
    b.installArtifact(probe);''')
p.write_text(s)
print(root)
