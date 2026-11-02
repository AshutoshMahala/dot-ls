//! Wire types and constants. No runtime or document-state dependency.
const std = @import("std");
const text = @import("../text/types.zig");
pub const server_version = @import("build_options").server_version ++ "; dot-parser 0.5.0 (01b0a8e)";
pub const Id = union(enum) {
    null,
    integer: i64,
    string: []const u8,
    pub fn jsonStringify(self: Id, json: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .null => try json.write(null),
            .integer => |n| try json.write(n),
            .string => |s| try json.write(s),
        }
    }
};
pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
    pub const not_initialized: i32 = -32002;
    pub const request_cancelled: i32 = -32800;
    pub const content_modified: i32 = -32801;
    pub const request_failed: i32 = -32803;
};
pub const Failure = struct { id: Id = .null, code: i32, message: []const u8 };
pub const FixData = struct { dot_ls_generation: u64, fix: usize };
pub const TextEdit = struct { range: text.Range, newText: []const u8 };
