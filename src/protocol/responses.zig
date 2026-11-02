//! Wire response encoding into bounded owned chunks. Views are borrowed only
//! through encoding; the protocol event loop writes queued frames independently.
const std = @import("std");
const output = @import("output.zig");
const lsp = @import("lsp.zig");
const pos = @import("../text/types.zig");
const completion_feature = @import("../features/completion.zig");
const attributes = @import("../features/attributes.zig");
const context = @import("../features/completion_context.zig");
const references = @import("../features/references.zig");
const outline = @import("../features/outline.zig");
const actions = @import("../features/code_actions.zig");
const findings = @import("../analysis/diagnostic_text.zig");
/// A borrowed writer with an optional final eligibility check. The check runs
/// after encoding and before the first frame byte. It does not own runtime data.
pub const Destination = struct {
    queue: *output.Queue,
    role: output.Role = .dispatcher,
    control: bool = false,
    tag: ?output.Tag = null,
    gate: ?struct { context: *anyopaque, current: *const fn (*anyopaque) bool } = null,
};
pub fn send(allocator: std.mem.Allocator, writer: Destination, value: anytype) !void {
    _ = allocator;
    var builder = try output.Builder.init(writer.queue, writer.role, writer.control, writer.tag);
    defer builder.deinit();
    std.json.Stringify.value(value, .{}, &builder.writer) catch return builder.failure;
    if (writer.gate) |gate| if (!gate.current(gate.context)) return;
    const frame = try builder.finish();
    errdefer writer.queue.destroy(frame);
    try writer.queue.enqueue(frame);
}
pub fn failure(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, code: i32, message: []const u8) !void {
    try send(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
}
pub fn result(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, value: anytype) !void {
    try send(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = value });
}
pub fn diagnostics(allocator: std.mem.Allocator, writer: Destination, uri: []const u8, version: ?i64, items: []const findings.Finding) !void {
    try send(allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = version, .diagnostics = Findings{ .items = items } } });
}
/// Borrowed serialization views; no copied diagnostic or related-note arrays.
const Findings = struct {
    items: []const findings.Finding,
    pub fn jsonStringify(self: Findings, json: *std.json.Stringify) std.json.Stringify.Error!void {
        try json.beginArray();
        for (self.items) |item| {
            const token: ?lsp.FixData = if (item.fix) |fix| .{ .dot_ls_generation = fix.generation, .fix = fix.index } else null;
            const severity: u8 = switch (item.severity) {
                .err => 1,
                .warning => 2,
                .information => 3,
            };
            try json.write(.{ .data = token, .range = item.range, .severity = severity, .code = item.code, .source = "dot-ls", .relatedInformation = Related{ .items = item.related }, .message = item.message });
        }
        try json.endArray();
    }
};
const Related = struct {
    items: []const findings.Related,
    pub fn jsonStringify(self: Related, json: *std.json.Stringify) std.json.Stringify.Error!void {
        try json.beginArray();
        for (self.items) |item| try json.write(.{ .location = .{ .uri = item.uri, .range = item.range }, .message = item.message });
        try json.endArray();
    }
};
pub fn clear(allocator: std.mem.Allocator, writer: Destination, uri: []const u8, version: ?i64, message: ?[]const u8) !void {
    const origin = pos.Position{ .line = 0, .character = 0 };
    const single = [_]findings.Finding{.{ .range = .{ .start = origin, .end = origin }, .severity = .information, .code = "dot-ls:limits", .message = message orelse "" }};
    try diagnostics(allocator, writer, uri, version, if (message != null) single[0..] else single[0..0]);
}
pub fn initialized(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, encoding: pos.Encoding) !void {
    const enc = switch (encoding) {
        .utf8 => "utf-8",
        .utf16 => "utf-16",
        .utf32 => "utf-32",
    };
    try result(allocator, writer, id, .{ .capabilities = .{ .positionEncoding = enc, .codeActionProvider = .{ .codeActionKinds = [_][]const u8{"quickfix"}, .resolveProvider = false }, .documentSymbolProvider = true, .referencesProvider = true, .hoverProvider = true, .completionProvider = .{ .resolveProvider = false }, .textDocumentSync = .{ .openClose = true, .change = 1 } }, .serverInfo = .{ .name = "dot-ls", .version = lsp.server_version } });
}
pub fn completion(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, index: context.Index, point: pos.Position) !void {
    try send(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = CompletionList{ .kind = index.at(point) } });
}
pub fn hover(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, index: context.Index, point: pos.Position, markdown: bool) !void {
    if (!index.attributes.available) return failure(allocator, writer, id, lsp.ErrorCode.request_failed, "Attribute hover exceeded its memory limit.");
    const byte = index.coordinates.byteAt(point);
    const match = if (byte) |b| index.attributes.at(b) else null;
    if (match) |key| {
        const entry = attributes.catalog.entries[key.id];
        var buffer: [2048]u8 = undefined;
        const text = try attributes.helpFormatted(&buffer, entry, markdown);
        try send(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = .{ .contents = .{ .kind = if (markdown) "markdown" else "plaintext", .value = text }, .range = .{ .start = index.coordinates.positionAt(key.span.start), .end = index.coordinates.positionAt(@intCast(key.span.endOffset())) } } });
    } else try send(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = @as(?u8, null) });
}
pub fn referencesReply(allocator: std.mem.Allocator, writer: Destination, request: lsp.Id, uri: []const u8, index: references.Index, point: pos.Position, include: bool) !void {
    const Location = struct { uri: []const u8, range: references.Range };
    var locations: std.ArrayList(Location) = .empty;
    defer locations.deinit(allocator);
    if (index.symbolAt(point)) |symbol| {
        var first = true;
        for (index.entries) |entry| if (entry.symbol == symbol) {
            if (include or !first) {
                if (locations.items.len == 10_000) {
                    try failure(allocator, writer, request, lsp.ErrorCode.request_failed, "Node has more than 10,000 reference results. Results were not truncated.");
                    return;
                }
                try locations.append(allocator, .{ .uri = uri, .range = index.range(entry) });
            }
            first = false;
        };
    }
    try send(allocator, writer, .{ .jsonrpc = "2.0", .id = request, .result = locations.items });
}
pub const CompletionList = struct {
    kind: @import("../features/completion_context.zig").Kind,
    pub fn jsonStringify(self: CompletionList, json: *@import("std").json.Stringify) @import("std").json.Stringify.Error!void {
        const attrs = @import("../features/attributes.zig");
        const target: ?attrs.Target = switch (self.kind) {
            .attr_graph => .graph,
            .attr_node => .node,
            .attr_edge => .edge,
            .attr_subgraph => .subgraph,
            .attr_cluster => .cluster,
            else => null,
        };
        try json.beginObject();
        try json.objectField("isIncomplete");
        try json.write(false);
        try json.objectField("items");
        try json.beginArray();
        if (target) |t| {
            for (attrs.catalog.entries) |entry| if (attrs.applies(entry, t)) {
                var buffer: [2048]u8 = undefined;
                const text = attrs.help(&buffer, entry) catch entry.type_name;
                try json.write(.{ .label = entry.name, .kind = @as(u8, 10), .insertText = entry.name, .detail = entry.type_name, .documentation = .{ .kind = "plaintext", .value = text } });
            };
        } else for (completion_feature.forContext(self.kind)) |entry| try json.write(.{ .label = entry.label, .kind = @as(u8, 14), .detail = entry.detail, .insertText = entry.label });
        try json.endArray();
        try json.endObject();
    }
};

fn symbolKind(kind: anytype) u8 {
    return switch (kind) {
        .graph => 3,
        .subgraph => 4,
        .cluster => 2,
        .node => 13,
    };
}
pub const Symbols = struct {
    index: outline.Index,
    pub fn jsonStringify(self: Symbols, json: *std.json.Stringify) !void {
        try json.beginArray();
        var i: usize = 0;
        while (i < self.index.entries.len) {
            try self.symbol(i, json);
            i = self.index.entries[i].next;
        }
        try json.endArray();
    }
    fn symbol(self: Symbols, i: usize, json: *std.json.Stringify) std.json.Stringify.Error!void {
        const e = self.index.entries[i];
        try json.beginObject();
        try json.objectField("name");
        try json.write(self.index.names[e.name_start..][0..e.name_len]);
        try json.objectField("kind");
        try json.write(symbolKind(e.kind));
        try json.objectField("range");
        try json.write(e.range);
        try json.objectField("selectionRange");
        try json.write(e.selection);
        if (i + 1 < e.next) {
            try json.objectField("children");
            try json.beginArray();
            var child = i + 1;
            while (child < e.next) {
                try self.symbol(child, json);
                child = self.index.entries[child].next;
            }
            try json.endArray();
        }
        try json.endObject();
    }
};
/// Older clients receive SymbolInformation instead of hierarchical symbols.
pub const FlatSymbols = struct {
    index: outline.Index,
    uri: []const u8,
    pub fn jsonStringify(self: FlatSymbols, json: *std.json.Stringify) !void {
        try json.beginArray();
        var stack: [257]u32 = undefined;
        var depth: usize = 0;
        for (self.index.entries, 0..) |e, i| {
            while (depth > 0 and self.index.entries[stack[depth - 1]].next <= i) depth -= 1;
            const container = if (depth > 0) blk: {
                const parent = self.index.entries[stack[depth - 1]];
                break :blk self.index.names[parent.name_start..][0..parent.name_len];
            } else "";
            try json.write(.{ .name = self.index.names[e.name_start..][0..e.name_len], .kind = symbolKind(e.kind), .location = .{ .uri = self.uri, .range = e.range }, .containerName = container });
            if (e.next > i + 1) {
                stack[depth] = @intCast(i);
                depth += 1;
            }
        }
        try json.endArray();
    }
};

fn wireEdits(offer: actions.Fix, storage: *[2]lsp.TextEdit) []const lsp.TextEdit {
    var edits: [2]actions.Edit = undefined;
    const values = offer.edits(&edits);
    for (values, 0..) |edit, i| storage[i] = .{ .range = edit.range, .newText = edit.text };
    return storage[0..values.len];
}
pub fn codeActions(gpa: std.mem.Allocator, writer: Destination, request: lsp.Id, uri: []const u8, version: i64, offers: []const actions.Fix, range: pos.Range) !void {
    const Change = struct { textDocument: struct { uri: []const u8, version: i64 }, edits: []const lsp.TextEdit };
    const Action = struct { title: []const u8, kind: []const u8 = "quickfix", isPreferred: bool, edit: struct { documentChanges: []const Change } };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var items: std.ArrayList(Action) = .empty;
    for (offers) |offer| {
        if (!offer.touches(range)) continue;
        const storage = try allocator.create([2]lsp.TextEdit);
        const changes = try allocator.alloc(Change, 1);
        changes[0] = .{ .textDocument = .{ .uri = uri, .version = version }, .edits = wireEdits(offer, storage) };
        try items.append(allocator, .{ .title = try offer.title(allocator), .isPreferred = offer.preferred, .edit = .{ .documentChanges = changes } });
    }
    try send(gpa, writer, .{ .jsonrpc = "2.0", .id = request, .result = items.items });
}

/// Select the client's wire outline shape without exposing runtime state.
pub fn outlineReply(allocator: std.mem.Allocator, writer: Destination, id: lsp.Id, index: outline.Index, uri: []const u8, hierarchical: bool) !void {
    if (hierarchical) return result(allocator, writer, id, Symbols{ .index = index });
    if (index.response_bound + index.entries.len * (6 * uri.len + 914) <= 128 * 1024 * 1024) return result(allocator, writer, id, FlatSymbols{ .index = index, .uri = uri });
    return failure(allocator, writer, id, lsp.ErrorCode.request_failed, "Flat outline response exceeded resource limits. Results were not truncated.");
}
