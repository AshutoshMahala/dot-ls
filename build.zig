const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const support = b.createModule(.{ .root_source_file = b.path("vendor/dot-parser/src/support.zig"), .target = target, .optimize = optimize });
    const parser = b.createModule(.{ .root_source_file = b.path("vendor/dot-parser/src/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "parser_support", .module = support }} });
    const markup = b.createModule(.{ .root_source_file = b.path("vendor/dot-parser/src/markup.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "parser_support", .module = support }} });
    const options = b.addOptions();
    const AllocatorKind = enum { page, smp, debug };
    const JsonStorage = enum { arena, buffer, inplace };
    options.addOption(AllocatorKind, "allocator_kind", b.option(AllocatorKind, "allocator", "Process allocator: page, smp, or debug") orelse .page);
    options.addOption(JsonStorage, "json_storage", b.option(JsonStorage, "json-storage", "JSON lifetime storage: arena, buffer, or inplace") orelse .buffer);
    options.addOption([]const u8, "server_version", b.option([]const u8, "version", "Packaged server version") orelse "0.0.1-dev");
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "dot_parser", .module = parser }, .{ .name = "markup_parser", .module = markup } } });
    root.addOptions("build_options", options);
    root.strip = b.option(bool, "strip", "Strip executable debug symbols") orelse false;
    const exe = b.addExecutable(.{ .name = "dot-ls", .root_module = root });
    b.installArtifact(exe);
    // Temporary executable compatibility alias for existing editor setups.
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = "dotls" }).step);
    const test_root = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "dot_parser", .module = parser }, .{ .name = "markup_parser", .module = markup } } });
    test_root.addOptions("build_options", options);
    const tests = b.addTest(.{ .root_module = test_root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    const parser_tests = b.addTest(.{ .root_module = parser });
    b.step("test-parser", "Run vendored parser unit and regression tests").dependOn(&b.addRunArtifact(parser_tests).step);
}
