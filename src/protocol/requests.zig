//! Typed borrowed commands. All views expire with Message/packet teardown.
//! No document lookup, request queue, source ownership transfer or output here.
const std = @import("std");
const lsp = @import("lsp.zig");
const text = @import("../text/types.zig");
pub const Capabilities = struct { versioned_edits: bool = false, hierarchical_symbols: bool = false, related_information: bool = false, hover_markdown: bool = false, encoding: text.Encoding = .utf16 };
pub const Positioned = struct { uri: []const u8, point: text.Position };
pub const References = struct { uri: []const u8, point: text.Position, include: bool };
pub const Update = struct { uri: []const u8, text: []const u8, version: i64, opening: bool };
pub const CodeActions = struct {
    uri: []const u8,
    range: text.Range,
    too_many: bool,
    only: enum { all, none, invalid_array, invalid_strings } = .all,
    generation: ?i64 = null,
    mixed_generations: bool = false,
};
pub const Method = enum { initialize, shutdown, exit, symbols, references, cancel, completion, hover, open, change, close, code_actions, unknown };
pub const Command = struct {
    id: ?lsp.Id,
    method: Method,
    body: union(enum) {
        none,
        initialize: Capabilities,
        symbols: ?[]const u8,
        references: ?References,
        positioned: ?Positioned,
        update: ?Update,
        close: ?[]const u8,
        cancel: ?lsp.Id,
        code_actions: ?CodeActions,
    },
};
pub const Decoded = union(enum) { command: Command, failure: lsp.Failure };
fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}
fn integer(v: std.json.Value) ?i64 {
    return if (v == .integer) v.integer else null;
}
fn identifier(v: std.json.Value) ?lsp.Id {
    return switch (v) {
        .integer => |n| .{ .integer = n },
        .string => |s| .{ .string = s },
        .null => .null,
        else => null,
    };
}
fn uri(params: std.json.Value) ?[]const u8 {
    return string(field(field(params, "textDocument") orelse .null, "uri") orelse .null);
}
fn point(value: std.json.Value, bounded: bool) ?text.Position {
    const line = integer(field(value, "line") orelse .null) orelse return null;
    const character = integer(field(value, "character") orelse .null) orelse return null;
    if (line < 0 or character < 0) return null;
    if (bounded and (line > std.math.maxInt(u32) or character > std.math.maxInt(u32))) return null;
    return .{ .line = @intCast(line), .character = @intCast(character) };
}
fn range(value: std.json.Value) ?text.Range {
    const start = point(field(value, "start") orelse .null, true) orelse return null;
    const end = point(field(value, "end") orelse .null, true) orelse return null;
    if (end.line < start.line or (end.line == start.line and end.character < start.character)) return null;
    return .{ .start = start, .end = end };
}
fn capabilities(params: std.json.Value) Capabilities {
    var result: Capabilities = .{};
    const caps = field(params, "capabilities") orelse .null;
    const hover = field(field(caps, "textDocument") orelse .null, "hover") orelse .null;
    if (field(hover, "contentFormat")) |formats| if (formats == .array) {
        for (formats.array.items) |value| {
            const format = string(value) orelse continue;
            if (std.mem.eql(u8, format, "markdown") or std.mem.eql(u8, format, "plaintext")) {
                result.hover_markdown = std.mem.eql(u8, format, "markdown");
                break;
            }
        }
    };
    const workspace_edit = field(field(caps, "workspace") orelse .null, "workspaceEdit") orelse .null;
    const document_changes = field(workspace_edit, "documentChanges") orelse .null;
    result.versioned_edits = document_changes == .bool and document_changes.bool;
    const hierarchy = field(field(field(caps, "textDocument") orelse .null, "documentSymbol") orelse .null, "hierarchicalDocumentSymbolSupport") orelse .null;
    result.hierarchical_symbols = hierarchy == .bool and hierarchy.bool;
    const publish = field(field(caps, "textDocument") orelse .null, "publishDiagnostics") orelse .null;
    const related = field(publish, "relatedInformation") orelse .null;
    result.related_information = related == .bool and related.bool;
    if (field(field(caps, "general") orelse .null, "positionEncodings")) |encodings| if (encodings == .array) {
        var has32 = false;
        for (encodings.array.items) |v| {
            const enc = string(v) orelse continue;
            if (std.mem.eql(u8, enc, "utf-32")) has32 = true;
            if (std.mem.eql(u8, enc, "utf-8")) {
                result.encoding = .utf8;
                break;
            }
        }
        if (result.encoding != .utf8 and has32) result.encoding = .utf32;
    };
    return result;
}
fn positioned(params: std.json.Value) ?Positioned {
    return .{ .uri = uri(params) orelse return null, .point = point(field(params, "position") orelse .null, false) orelse return null };
}
fn references(params: std.json.Value) ?References {
    const p = positioned(params) orelse return null;
    const include = field(field(params, "context") orelse .null, "includeDeclaration") orelse .null;
    if (include != .bool) return null;
    return .{ .uri = p.uri, .point = p.point, .include = include.bool };
}
fn update(params: std.json.Value, opening: bool) ?Update {
    const document = field(params, "textDocument") orelse return null;
    const u = string(field(document, "uri") orelse .null) orelse return null;
    if (u.len > 8192) return null;
    const version = integer(field(document, "version") orelse .null) orelse return null;
    var source = if (opening) string(field(document, "text") orelse .null) else null;
    if (!opening) {
        const changes = field(params, "contentChanges") orelse return null;
        if (changes != .array) return null;
        for (changes.array.items) |change| {
            if (field(change, "range") != null) return null;
            source = string(field(change, "text") orelse .null) orelse return null;
        }
    }
    return .{ .uri = u, .text = source orelse return null, .version = version, .opening = opening };
}
fn codeActions(params: std.json.Value) ?CodeActions {
    const context = field(params, "context") orelse .null;
    const diagnostics = field(context, "diagnostics") orelse .null;
    const u = uri(params) orelse return null;
    const r = range(field(params, "range") orelse .null) orelse return null;
    if (diagnostics != .array) return null;
    var result: CodeActions = .{ .uri = u, .range = r, .too_many = diagnostics.array.items.len > 1024 };
    if (result.too_many) return result;
    if (field(context, "only")) |only| {
        if (only != .array or only.array.items.len > 64) {
            result.only = .invalid_array;
            return result;
        }
        var wanted = false;
        for (only.array.items) |item| {
            const kind = string(item) orelse {
                result.only = .invalid_strings;
                return result;
            };
            if (kind.len == 0 or std.mem.eql(u8, kind, "quickfix")) wanted = true;
        }
        result.only = if (wanted) .all else .none;
    }
    for (diagnostics.array.items) |diagnostic| {
        const data = field(diagnostic, "data") orelse .null;
        if (integer(field(data, "dot_ls_generation") orelse .null)) |generation| {
            if (result.generation) |previous| if (previous != generation) {
                result.mixed_generations = true;
            };
            result.generation = generation;
        }
    }
    return result;
}
pub const Lifecycle = enum { before_initialize, ready, shutdown };
pub fn decode(value: std.json.Value, lifecycle: Lifecycle) Decoded {
    var id: ?lsp.Id = null;
    if (field(value, "id")) |v| id = identifier(v) orelse return .{ .failure = .{ .code = lsp.ErrorCode.invalid_request, .message = "Invalid request ID" } };
    const method = string(field(value, "method") orelse .null) orelse return .{ .failure = .{ .id = id orelse .null, .code = lsp.ErrorCode.invalid_request, .message = "Invalid request" } };
    if (!std.mem.eql(u8, string(field(value, "jsonrpc") orelse .null) orelse "", "2.0")) return .{ .failure = .{ .id = id orelse .null, .code = lsp.ErrorCode.invalid_request, .message = "Invalid JSON-RPC version" } };
    const params = field(value, "params") orelse .null;
    const m: Method = if (std.mem.eql(u8, method, "initialize")) .initialize else if (std.mem.eql(u8, method, "shutdown")) .shutdown else if (std.mem.eql(u8, method, "exit")) .exit else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) .symbols else if (std.mem.eql(u8, method, "textDocument/references")) .references else if (std.mem.eql(u8, method, "$/cancelRequest")) .cancel else if (std.mem.eql(u8, method, "textDocument/completion")) .completion else if (std.mem.eql(u8, method, "textDocument/hover")) .hover else if (std.mem.eql(u8, method, "textDocument/didOpen")) .open else if (std.mem.eql(u8, method, "textDocument/didChange")) .change else if (std.mem.eql(u8, method, "textDocument/didClose")) .close else if (std.mem.eql(u8, method, "textDocument/codeAction")) .code_actions else .unknown;
    // Preserve lifecycle precedence and avoid walking ignored parameter arrays.
    const active = lifecycle == .ready;
    const request = active and id != null;
    return .{ .command = .{ .id = id, .method = m, .body = switch (m) {
        .initialize => .{ .initialize = if (lifecycle == .before_initialize and id != null) capabilities(params) else .{} },
        .symbols => .{ .symbols = if (request) uri(params) else null },
        .references => .{ .references = if (request) references(params) else null },
        .completion, .hover => .{ .positioned = if (request) positioned(params) else null },
        .open, .change => .{ .update = if (active) update(params, m == .open) else null },
        .close => .{ .close = if (active) uri(params) else null },
        .cancel => .{ .cancel = if (active) identifier(field(params, "id") orelse .null) else null },
        .code_actions => .{ .code_actions = if (request) codeActions(params) else null },
        else => .none,
    } } };
}

test "typed commands preserve IDs capabilities and full-sync source views" {
    const messages = @import("json_message.zig");
    var message: messages.Message = .{ .allocator = std.testing.allocator };
    defer message.deinit();
    try message.parse("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-32\",\"utf-8\"]},\"workspace\":{\"workspaceEdit\":{\"documentChanges\":true}}}}}", .buffer);
    const command = decode(message.value, .before_initialize).command;
    try std.testing.expect(command.id.? == .null);
    try std.testing.expectEqual(text.Encoding.utf8, command.body.initialize.encoding);
    try std.testing.expect(command.body.initialize.versioned_edits);
    var change: messages.Message = .{ .allocator = std.testing.allocator };
    defer change.deinit();
    try change.parse("{\"jsonrpc\":\"2.0\",\"id\":\"quoted id\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"untitled:test\",\"version\":2},\"contentChanges\":[{\"text\":\"first\"},{\"text\":\"last\"}]}}", .buffer);
    const parsed = decode(change.value, .ready).command;
    try std.testing.expectEqualStrings("quoted id", parsed.id.?.string);
    try std.testing.expectEqualStrings("last", parsed.body.update.?.text);
    try std.testing.expect(!parsed.body.update.?.opening);
}

test "request envelope failures precede parameter validation" {
    const messages = @import("json_message.zig");
    const sources = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":[],\"method\":\"initialize\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3}",
        "{\"jsonrpc\":\"1.0\",\"id\":3,\"method\":\"textDocument/hover\"}",
    };
    const expected = [_][]const u8{ "Invalid request ID", "Invalid request", "Invalid JSON-RPC version" };
    for (sources, expected) |source, msg| {
        var message: messages.Message = .{ .allocator = std.testing.allocator };
        defer message.deinit();
        try message.parse(source, .buffer);
        const failure = decode(message.value, .before_initialize).failure;
        try std.testing.expectEqual(@as(i32, -32600), failure.code);
        try std.testing.expectEqualStrings(msg, failure.message);
    }
}
