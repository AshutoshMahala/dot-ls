//! Static attribute help and compressed key spans. No source or syntax tree is retained.
const std = @import("std");
const dot = @import("dot_parser");
pub const catalog = dot.attribute_catalog;
comptime {
    if (catalog.entries.len > 256) @compileError("attribute IDs need a wider encoding");
}
pub const Target = enum { graph, node, edge, subgraph, cluster };
pub const max_bytes = 8 * 1024 * 1024;
const Anchor = struct { start: u32, base: u32, cursor: u32 };
pub const Match = struct { span: dot.Span, id: u8 };
pub fn applies(entry: catalog.Entry, target: Target) bool {
    return switch (target) {
        .graph => entry.targets.graph,
        .node => entry.targets.node,
        .edge => entry.targets.edge,
        .subgraph => entry.targets.subgraph,
        .cluster => entry.targets.cluster or entry.targets.subgraph,
    };
}
pub fn help(buffer: []u8, entry: catalog.Entry) ![]const u8 {
    return helpFormatted(buffer, entry, false);
}
/// Catalog-only content, formatted on demand into bounded caller storage.
/// No document text is interpreted as Markdown and no per-document data is added.
pub fn helpFormatted(buffer: []u8, entry: catalog.Entry, markdown: bool) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    if (markdown) try out.print("**`{s}`**\n\n{s}\n\n", .{ entry.name, description(entry.name) }) else try out.print("{s}\n\n{s}\n\n", .{ entry.name, description(entry.name) });
    try metadata(&out, "Type", entry.type_name, markdown);
    try metadata(&out, "Default", if (entry.default_value.len == 0) "not specified" else entry.default_value, markdown);
    if (entry.minimum.len > 0) try metadata(&out, "Minimum", entry.minimum, markdown);
    try out.writeAll(if (markdown) "- **Applies to:** " else "Applies to: ");
    var first = true;
    inline for (.{ "graph", "node", "edge", "cluster", "subgraph" }) |target| {
        if (@field(entry.targets, target)) {
            if (!first) try out.writeAll(", ");
            try out.writeAll(target);
            first = false;
        }
    }
    if (example(entry.name)) |sample| {
        if (markdown) try out.print("\n\n```dot\n{s}\n```", .{sample}) else try out.print("\n\nExample:\n{s}", .{sample});
    }
    if (markdown) try out.print("\n\n[Graphviz reference](https://graphviz.org/docs/attrs/{s}/)", .{entry.name}) else try out.print("\n\nReference: https://graphviz.org/docs/attrs/{s}/", .{entry.name});
    return out.buffered();
}
fn metadata(out: *std.Io.Writer, label: []const u8, value: []const u8, markdown: bool) !void {
    if (markdown) try out.print("- **{s}:** `{s}`\n", .{ label, value }) else try out.print("{s}: {s}\n", .{ label, value });
}
fn example(name: []const u8) ?[]const u8 {
    const samples = .{
        .{ "shape", "start [shape=box];" },
        .{ "label", "start [label=\"Start here\"];" },
        .{ "color", "start [color=blue];" },
        .{ "fillcolor", "start [style=filled, fillcolor=lightblue];" },
        .{ "rankdir", "graph [rankdir=LR];" },
        .{ "rank", "{ rank=same; start; finish; }" },
        .{ "fontsize", "start [fontsize=14];" },
        .{ "fontname", "start [fontname=\"Helvetica\"];" },
        .{ "arrowhead", "start -> finish [arrowhead=vee];" },
        .{ "weight", "start -> finish [weight=2];" },
    };
    inline for (samples) |sample| if (std.mem.eql(u8, name, sample[0])) return sample[1];
    return null;
}
fn description(name: []const u8) []const u8 {
    const descriptions = .{
        .{ "shape", "The shape used to draw a node." },
        .{ "label", "Text or an HTML-like label displayed on the object." },
        .{ "color", "The color used to draw the object." },
        .{ "fillcolor", "The fill color used inside the object." },
        .{ "rankdir", "The direction in which graph ranks are drawn." },
        .{ "rank", "The rank constraint for nodes in a subgraph." },
        .{ "fontsize", "The font size used for the label, in points." },
        .{ "fontname", "The font used to draw the label." },
        .{ "arrowhead", "The arrowhead shape at the head of an edge." },
        .{ "weight", "The weight used when laying out an edge." },
    };
    inline for (descriptions) |d| if (std.mem.eql(u8, name, d[0])) return d[1];
    return "Graphviz attribute. The value and default can depend on the layout engine.";
}
fn read(data: []const u8, cursor: *usize) u32 {
    var value: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const b = data[cursor.*];
        cursor.* += 1;
        value |= @as(u32, b & 127) << shift;
        if (b & 128 == 0) return value;
        shift += 7;
    }
}
pub const Index = struct {
    data: []u8 = &.{},
    anchors: []Anchor = &.{},
    available: bool = true,
    pub fn bytes(self: Index) usize {
        return self.data.len + self.anchors.len * @sizeOf(Anchor);
    }
    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.anchors);
        self.* = .{};
    }
    pub fn at(self: Index, byte: u32) ?Match {
        if (self.anchors.len == 0 or byte < self.anchors[0].start) return null;
        var lo: usize = 0;
        var hi = self.anchors.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.anchors[mid].start <= byte) lo = mid else hi = mid;
        }
        var cursor: usize = self.anchors[lo].cursor;
        var start = self.anchors[lo].base;
        for (0..128) |_| {
            if (cursor == self.data.len) break;
            start += read(self.data, &cursor);
            const len = read(self.data, &cursor);
            const id = self.data[cursor];
            cursor += 1;
            if (start > byte) break;
            if (byte - start < len) return .{ .span = .{ .start = start, .len = len }, .id = id };
        }
        return null;
    }
};
pub const Builder = struct {
    data: std.ArrayList(u8) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    last: u32 = 0,
    count: usize = 0,
    failed: bool = false,
    pub fn bytes(self: Builder) usize {
        return self.data.capacity + self.anchors.capacity * @sizeOf(Anchor);
    }
    pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        self.anchors.deinit(gpa);
        self.data = .empty;
        self.anchors = .empty;
    }
    pub fn add(self: *Builder, gpa: std.mem.Allocator, span: dot.Span, raw: []const u8) void {
        if (self.failed) return;
        var decoded: [32]u8 = undefined;
        const name = if (raw.len > 0 and raw[0] == '"') blk: {
            if (raw.len > 256) return;
            break :blk dot.identifier.decodeInto(raw, &decoded) catch return;
        } else raw;
        const entry = catalog.lookup(name) orelse return;
        const id: u8 = @intCast((@intFromPtr(entry) - @intFromPtr(&catalog.entries[0])) / @sizeOf(catalog.Entry));
        self.append(gpa, span, id) catch {
            self.deinit(gpa);
            self.failed = true;
        };
    }
    fn append(self: *Builder, gpa: std.mem.Allocator, span: dot.Span, id: u8) !void {
        if (span.start < self.last) return error.UnorderedAttribute;
        var buffer: [11]u8 = undefined;
        var n: usize = 0;
        for ([_]u32{ span.start - self.last, span.len }) |input| {
            var value = input;
            while (value >= 128) {
                buffer[n] = @as(u8, @intCast(value & 127)) | 128;
                n += 1;
                value >>= 7;
            }
            buffer[n] = @intCast(value);
            n += 1;
        }
        buffer[n] = id;
        n += 1;
        if (self.data.items.len + n > self.data.capacity) {
            const capacity = @max(self.data.items.len + n, self.data.capacity + self.data.capacity / 2 + 64);
            if (capacity + self.anchors.capacity * @sizeOf(Anchor) > max_bytes) return error.AttributeLimit;
            try self.data.ensureTotalCapacityPrecise(gpa, capacity);
        }
        if (self.count % 128 == 0) {
            if (self.anchors.items.len == self.anchors.capacity) {
                const capacity = self.anchors.capacity + self.anchors.capacity / 2 + 16;
                if (self.data.capacity + capacity * @sizeOf(Anchor) > max_bytes) return error.AttributeLimit;
                try self.anchors.ensureTotalCapacityPrecise(gpa, capacity);
            }
            self.anchors.appendAssumeCapacity(.{ .start = span.start, .base = self.last, .cursor = @intCast(self.data.items.len) });
        }
        self.data.appendSliceAssumeCapacity(buffer[0..n]);
        self.last = span.start;
        self.count += 1;
    }
    pub fn finish(self: *Builder, gpa: std.mem.Allocator) !Index {
        if (self.failed) return .{ .available = false };
        var index: Index = .{};
        errdefer index.deinit(gpa);
        index.data = try self.data.toOwnedSlice(gpa);
        index.anchors = try self.anchors.toOwnedSlice(gpa);
        return index;
    }
};

test "compact keys own spans, skip unknown names, and cross anchor boundaries" {
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    for (0..300) |i| builder.add(std.testing.allocator, .{ .start = @intCast(i * 32), .len = 5 }, "shape");
    var index = try builder.finish(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    for (0..300) |i| {
        const match = index.at(@intCast(i * 32 + 2)).?;
        try std.testing.expectEqualStrings("shape", catalog.entries[match.id].name);
        try std.testing.expect(index.at(@intCast(i * 32 + 5)) == null);
    }
    try std.testing.expect(index.bytes() < 300 * 5);
    var failure: Builder = .{};
    defer failure.deinit(std.testing.allocator);
    failure.add(std.testing.failing_allocator, .{ .start = 0, .len = 5 }, "shape");
    try std.testing.expect(failure.failed);
    try std.testing.expect(!(try failure.finish(std.testing.allocator)).available);
}

test "all catalog help fits request scratch and describes attribute owners" {
    var buffer: [2048]u8 = undefined;
    for (catalog.entries) |entry| {
        const text = try help(&buffer, entry);
        try std.testing.expect(std.mem.indexOf(u8, text, "Type:") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Applies to:") != null);
        const markdown = try helpFormatted(&buffer, entry, true);
        try std.testing.expect(std.mem.startsWith(u8, markdown, "**`"));
        try std.testing.expect(std.mem.indexOf(u8, markdown, "[Graphviz reference]") != null);
        // Catalog metadata is the only Markdown input. Reject markup delimiters
        // here if the dependency adds a value that needs an escaping strategy.
        for ([_][]const u8{ entry.name, entry.type_name, entry.default_value, entry.minimum }) |value|
            try std.testing.expect(std.mem.indexOfAny(u8, value, "`\r\n") == null);
    }
    try std.testing.expect(applies(catalog.lookup("shape").?.*, .node));
    try std.testing.expect(!applies(catalog.lookup("shape").?.*, .edge));
    try std.testing.expect(applies(catalog.lookup("rank").?.*, .cluster));
}
