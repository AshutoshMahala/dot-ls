//! Compact declaration outline. No retained source, attributes, edges or AST.
const std = @import("std");
const dot = @import("dot_parser");
const text_coordinates = @import("../text/coordinates.zig");
const pos = @import("../text/positions.zig");
const Span = dot.Span;
pub const max_entries = 250_000;
pub const max_bytes = 32 * 1024 * 1024;
pub const global_bytes = 64 * 1024 * 1024;
const none = std.math.maxInt(u32);
const Kind = enum(u8) { graph, subgraph, cluster, node };
const Point = struct { line: u32, character: u32 };
const Range = struct { start: Point, end: Point };
const Entry = struct { range: Range, selection: Range, name_start: u32, name_len: u32, next: u32, kind: Kind };
const Raw = struct { name: Span, start: u32, end: u32, next: u32, kind: Kind, anonymous: bool = false };
const Pending = struct { owner: dot.events.Owner, name: Span, end: u32, node: bool = false };
pub const Index = struct {
    entries: []Entry,
    names: []u8,
    response_bound: usize,
    pub fn bytes(self: Index) usize {
        return self.entries.len * @sizeOf(Entry) + self.names.len;
    }
    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.names);
    }
};
pub const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    raw: std.ArrayList(Raw) = .empty,
    stack: [257]u32 = undefined,
    depth: usize = 0,
    failed: bool = false,
    pending: ?Pending = null,
    pub fn deinit(self: *Builder) void {
        self.raw.deinit(self.allocator);
    }
    /// Public parser facts only. A statement start is tentative until its head
    /// or commit identifies a node; terminal EOF is handled by abort below.
    pub fn observe(ctx: *anyopaque, event: dot.events.Event) void {
        const self: *Builder = @ptrCast(@alignCast(ctx));
        if (self.failed) return;
        switch (event) {
            .begin_document => |g| self.open(g.keyword_span, if (g.name_span) |name| name.span() else null, .graph),
            .begin_scope => |g| {
                self.pending = null;
                self.open(g.start, if (g.name) |name| name.span() else null, .subgraph);
            },
            .begin_statement => |s| self.pending = .{ .owner = s.owner, .name = s.start, .end = @intCast(s.start.endOffset()) },
            .statement_head => |h| if (self.pending) |*pending| {
                if (!std.meta.eql(pending.owner, h.owner)) return;
                if (h.kind == .node) {
                    pending.node = true;
                    self.node(pending.name, pending.end);
                } else self.pending = null;
            },
            .ported_reference => |p| if (self.pending) |*pending| {
                if (std.meta.eql(pending.owner, p.owner) and pending.name.start == p.reference.identifier.start) {
                    pending.end = @intCast((p.reference.second orelse p.reference.first).endOffset());
                }
            },
            .commit_node => |n| {
                const name = n.value.identifier.span();
                self.node(name, @intCast(n.extent.?.endOffset()));
                self.pending = null;
            },
            .delimiter => |d| {
                if (d.skipped or d.side != .close) return;
                if (d.kind == .brace) self.close(d.span) else if (self.pending) |*pending| {
                    if (pending.node and pending.owner.scope == d.scope) {
                        pending.end = @intCast(d.span.endOffset());
                        self.node(pending.name, pending.end);
                    }
                }
            },
            else => {},
        }
    }
    /// Only an actual EOF error in node-ending grammar permits an undecided
    /// bare/ported name to remain provisional. Other aborted starts are omitted.
    pub fn abort(self: *Builder, event: dot.events.Abort, node_eof: bool) void {
        if (self.failed) return;
        switch (event) {
            .statement => |s| if (self.pending) |pending| {
                if (node_eof and s.span.len == 0 and std.meta.eql(pending.owner, s.owner)) self.node(pending.name, pending.end);
                self.pending = null;
            },
            .document => self.pending = null,
        }
    }
    fn close(self: *Builder, close_span: Span) void {
        self.pending = null;
        if (self.depth > 0) {
            self.depth -= 1;
            const e = &self.raw.items[self.stack[self.depth]];
            e.end = @intCast(close_span.endOffset());
            e.next = @intCast(self.raw.items.len);
        }
    }
    fn node(self: *Builder, name: Span, end: u32) void {
        if (self.depth == 0) return;
        if (self.raw.items.len > 0) {
            const last = &self.raw.items[self.raw.items.len - 1];
            if (last.kind == .node and last.name.start == name.start) {
                last.end = @max(last.end, end);
                return;
            }
        }
        self.append(.{ .name = name, .start = name.start, .end = @intCast(@max(name.endOffset(), end)), .next = @intCast(self.raw.items.len + 1), .kind = .node });
    }
    fn append(self: *Builder, entry: Raw) void {
        if (self.raw.items.len == max_entries) {
            self.failed = true;
            return;
        }
        self.raw.append(self.allocator, entry) catch {
            self.failed = true;
        };
    }
    fn open(self: *Builder, start: Span, name: ?Span, kind: Kind) void {
        if (self.depth == self.stack.len) {
            self.failed = true;
            return;
        }
        self.stack[self.depth] = @intCast(self.raw.items.len);
        self.depth += 1;
        self.append(.{ .name = name orelse start, .start = start.start, .end = @intCast(self.source.len), .next = none, .kind = kind, .anonymous = name == null and kind == .subgraph });
    }
    pub fn finish(self: *Builder, coordinates: text_coordinates.Index, cancel: *const std.atomic.Value(bool), waiting: *const std.atomic.Value(usize)) !Index {
        if (self.failed) return error.ResourceLimit;
        const entries = try self.allocator.alloc(Entry, self.raw.items.len);
        errdefer self.allocator.free(entries);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(self.allocator);
        var wire_bound: usize = 0;
        for (self.raw.items, 0..) |r, i| {
            if (i % 256 == 0) {
                if (cancel.load(.acquire)) return error.Cancelled;
                if (waiting.load(.acquire) != 0) return error.Yield;
            }
            var decoded: [4096]u8 = undefined;
            const raw_name = self.source[r.name.start..][0..r.name.len];
            const value = if (r.anonymous) "{…}" else if (raw_name.len <= decoded.len) dot.identifier.decodeInto(raw_name, &decoded) catch raw_name else raw_name;
            const logical = if (value.len == 0) raw_name else value;
            var end = @min(logical.len, 128);
            while (end > 0 and end < logical.len and logical[end] & 0xc0 == 0x80) end -= 1;
            const truncated = end < logical.len;
            const name_start: u32 = @intCast(names.items.len);
            try names.appendSlice(self.allocator, logical[0..end]);
            if (truncated) try names.appendSlice(self.allocator, "…");
            const name_len: u32 = @intCast(names.items.len - name_start);
            // Bound both the retained payload and worst-case escaped JSON.
            wire_bound += 272 + 6 * name_len;
            if (entries.len * @sizeOf(Entry) + names.items.len > max_bytes or wire_bound > 128 * 1024 * 1024) return error.ResourceLimit;
            entries[i] = .{ .range = .{ .start = point(coordinates.positionAt(r.start)), .end = point(coordinates.positionAt(r.end)) }, .selection = .{ .start = point(coordinates.positionAt(r.name.start)), .end = point(coordinates.positionAt(@intCast(r.name.endOffset()))) }, .name_start = name_start, .name_len = name_len, .next = if (r.next == none) @intCast(entries.len) else r.next, .kind = if (r.kind == .subgraph and std.mem.startsWith(u8, logical, "cluster")) .cluster else r.kind };
        }
        return .{ .entries = entries, .names = try names.toOwnedSlice(self.allocator), .response_bound = wire_bound };
    }
};
fn point(p: pos.Position) Point {
    return .{ .line = @intCast(p.line), .character = @intCast(p.character) };
}

test "outline storage is compact and allocation failure is explicit" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Raw));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Entry));
    var b: Builder = .{ .allocator = std.testing.failing_allocator, .source = "digraph{}" };
    defer b.deinit();
    b.open(.{ .start = 0, .len = 7 }, null, .graph);
    try std.testing.expect(b.failed);
    var cancel: std.atomic.Value(bool) = .init(false);
    var waiting: std.atomic.Value(usize) = .init(0);
    try std.testing.expectError(error.ResourceLimit, b.finish(.{}, &cancel, &waiting));
}

test "outline conversion cancellation yield and allocation failures release temporary storage" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var waiting: std.atomic.Value(usize) = .init(0);
    const source = "digraph G {}";
    var coordinate_builder: text_coordinates.Builder = .{ .gpa = std.testing.allocator, .source = source, .cancel = &cancel, .waiting = &waiting };
    defer coordinate_builder.deinit();
    try coordinate_builder.scan(.utf16, 0, 64 * 1024 * 1024);
    var coordinates = try coordinate_builder.finish();
    defer coordinates.deinit(std.testing.allocator);
    var builder: Builder = .{ .allocator = std.testing.allocator, .source = source };
    defer builder.deinit();
    builder.open(.{ .start = 0, .len = 7 }, .{ .start = 8, .len = 1 }, .graph);
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, builder.finish(coordinates, &cancel, &waiting));
    cancel.store(false, .release);
    waiting.store(1, .release);
    try std.testing.expectError(error.Yield, builder.finish(coordinates, &cancel, &waiting));
    waiting.store(0, .release);
    builder.allocator = std.testing.failing_allocator;
    try std.testing.expectError(error.OutOfMemory, builder.finish(coordinates, &cancel, &waiting));
    builder.allocator = std.testing.allocator;
    var index = try builder.finish(coordinates, &cancel, &waiting);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 49), index.bytes());
}
