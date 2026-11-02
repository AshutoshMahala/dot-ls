#!/usr/bin/env python3
"""Instrument a temporary source copy. The normal executable is unchanged."""
import pathlib,tempfile,shutil
project=pathlib.Path(__file__).resolve().parent.parent
root=pathlib.Path(tempfile.mkdtemp(prefix='dotls-profile-',dir='/private/tmp'))
for name in ('src','vendor'):shutil.copytree(project/name,root/name)
for name in ('build.zig','build.zig.zon'):shutil.copy(project/name,root/name)
shutil.copy(project/'tools/profile.zig',root/'src/profile.zig')
(root/'src/pause.zig').write_text('pub const enabled = false;\n')
p=root/'src/main.zig';s=p.read_text()
def change(old,new):
    global s
    assert old in s,old
    s=s.replace(old,new,1)
s='const profile = @import("profile.zig");\n'+s
change('    generation: u64,\n    cancel:', '    generation: u64,\n    queued: i96 = 0,\n    cancel:')
change('allocator.free(self.allocation);','profile.allocator(if (build_options.json_storage == .inplace) .input else .snapshot).free(self.allocation);')
change('        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});\n        defer self.allocator.free(bytes);','''        const t_encode = profile.now();
        const bytes = try std.json.Stringify.valueAlloc(profile.allocator(.response), value, .{});
        defer profile.allocator(.response).free(bytes);
        profile.mark("response_encode",profile.now()-t_encode);
        const t_write = profile.now();''')
change('        try self.writer.flush();','        try self.writer.flush();\n        profile.mark("response_write",profile.now()-t_write);')
change('        const source = if (message.inplace) text else try self.allocator.dupe(u8, text);\n        errdefer if (!message.inplace) self.allocator.free(source);', '\n'.join([
    '        const t_copy = profile.now();',
    '        const source = if (message.inplace) text else try profile.allocator(.snapshot).dupe(u8,text);',
    '        errdefer if (!message.inplace) profile.allocator(.snapshot).free(source);',
    '        profile.mark("snapshot_copy",profile.now()-t_copy);']))
change('        doc.pending = job;','        job.queued = profile.now();\n        doc.pending = job;')
change('            self.analyze(job.?, encoding)','            profile.mark("worker_queue",profile.now()-job.?.queued);\n            self.analyze(job.?, encoding)')
change('            job.?.destroy(self.allocator);','            const t_cleanup = profile.now();\n            job.?.destroy(self.allocator);\n            profile.mark("job_cleanup",profile.now()-t_cleanup);')
change('        const result = analysis.run(job.text, scratch.storage(), &bag,','        const t_parser = profile.now();\n        const result = analysis.run(job.text, scratch.storage(), &bag,')
change('        if (result.outcome == .cancelled','        profile.mark("parser",profile.now()-t_parser);\n        const t_position = profile.now();\n        if (result.outcome == .cancelled')
change('        const i = self.find(job.uri) orelse return;','        profile.mark("diagnostic_conversion",profile.now()-t_position);\n        const i = self.find(job.uri) orelse return;')
change('pub fn main(init: std.process.Init) !void {','pub fn main(init: std.process.Init) !void {\n    profile.io = init.io;')
change('    const allocator = switch (build_options.allocator_kind)','    const backing_allocator = switch (build_options.allocator_kind)')
change('    const args = try init.minimal.args.toSlice(allocator);','    profile.backing = backing_allocator;\n    const allocator = profile.allocator(.misc);\n    const args = try init.minimal.args.toSlice(allocator);')
change('while (try readMessage(&input.interface, allocator)) |bytes| {', 'while (try readMessage(&input.interface,profile.allocator(.input))) |bytes| {')
change('defer if (packet) |owned| allocator.free(owned);', '\n'.join([
    'defer {',
    '                const t_free = profile.now();',
    '                if (packet) |owned| profile.allocator(.input).free(owned);',
    '                profile.mark("input_cleanup",profile.now()-t_free);',
    '            }']))
change('var parsed: json_message.Message = .{ .allocator = allocator };\n            defer parsed.deinit();','''var parsed: json_message.Message = .{ .allocator = profile.allocator(.json) };
            defer {
                const t_free = profile.now();
                parsed.deinit();
                profile.mark("json_cleanup",profile.now()-t_free);
            }
            const t_decode = profile.now();''')
change('            if (try server.handle(&parsed, &packet))','            profile.json_used.store(if (parsed.buffer != null) parsed.fixed.end_index else 0, .monotonic);\n            profile.mark("json_decode",profile.now()-t_decode);\n            if (try server.handle(&parsed, &packet))')
change('    try reader.readSliceAll(bytes);','    const t_read = profile.now();\n    try reader.readSliceAll(bytes);\n    profile.mark("body_read",profile.now()-t_read);')
change('pos.Index.initCancellable(self.allocator, job.text, &job.cancel)', 'pos.Index.initCancellable(profile.allocator(.positions), job.text, &job.cancel)')
change('defer index.deinit(self.allocator);', 'defer index.deinit(profile.allocator(.positions));\n            profile.mark("positions_ready",0);')
p.write_text(s)
for source,name in [('parser_bench','parser-profile'),('scanner_bench','scanner-profile'),('session_bench','session-profile')]:
    shutil.copy(project/'tools'/(source+'.zig'),root/'src'/(source+'.zig'))
    p=root/'build.zig';build=p.read_text();marker='    b.installArtifact(exe);'
    extra='\n    const '+source+' = b.addExecutable(.{ .name = "'+name+'", .root_module = b.createModule(.{ .root_source_file = b.path("src/'+source+'.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "dot_parser", .module = parser }} }) });\n    b.installArtifact('+source+');'
    build=build.replace(marker,marker+extra,1);p.write_text(build)
print(root)
