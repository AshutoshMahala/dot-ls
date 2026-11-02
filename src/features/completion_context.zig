//! Compressed lexical completion regions. No retained source or AST.
const std = @import("std");
const dot = @import("dot_parser");
const pos = @import("../text/positions.zig");
const attributes = @import("attributes.zig");
pub const Kind = enum(u4) { none, header, graph_kind, body, endpoint, attr_graph, attr_node, attr_edge, attr_subgraph, attr_cluster };
const Anchor = struct { byte: u32, cursor: u32, kind: Kind };
const text_coordinates = @import("../text/coordinates.zig");
pub const max_bytes = 64 * 1024 * 1024;
pub const Index = struct {
    events: []u8 = &.{},
    anchors: []Anchor = &.{},
    coordinates: text_coordinates.Index = .{},
    attributes: attributes.Index = .{},
    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        self.attributes.deinit(gpa);
        gpa.free(self.events);
        gpa.free(self.anchors);
        self.coordinates.deinit(gpa);
        self.* = .{};
    }
    pub fn bytes(self: Index) usize {
        return self.attributes.bytes() + self.events.len + self.anchors.len * @sizeOf(Anchor) + self.coordinates.bytes();
    }
    pub fn at(self: Index, point: pos.Position) Kind {
        if (self.anchors.len == 0) return .none;
        const byte = self.coordinates.byteAt(point) orelse return .none;
        var lo: usize = 0;
        var hi: usize = 0;
        lo = 0;
        hi = self.anchors.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.anchors[mid].byte <= byte) lo = mid else hi = mid;
        }
        const anchor = self.anchors[lo];
        var offset = anchor.byte;
        var cursor: usize = anchor.cursor;
        var kind = anchor.kind;
        while (cursor < self.events.len) {
            var code: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                const b = self.events[cursor];
                cursor += 1;
                code |= @as(u32, b & 127) << shift;
                if (b & 128 == 0) break;
                shift += 7;
            }
            offset += code >> 4;
            if (offset > byte) break;
            kind = @fromBackingInt(@as(u4, @truncate(code)));
        }
        return kind;
    }
};
const State = struct {
    const Mode = enum { statement, after_id, after_scope, endpoint, value, port, attributes, sub_name, sub_open, unknown };
    const Frame = struct { scope: @import("attributes.zig").Target, outer: @import("attributes.zig").Target };
    root: enum { start, strict, name, open, bad, graph, done } = .start,
    mode: Mode = .statement,
    depth: u32 = 0,
    attributes: u32 = 0,
    owner: @import("attributes.zig").Target = .node,
    scope: @import("attributes.zig").Target = .graph,
    pending_scope: @import("attributes.zig").Target = .subgraph,
    frames: [257]Frame = undefined,
    attribute_phase: enum { key, equals, value } = .key,
    attribute_valid: bool = false,
    fn attributeKind(self: *const State) Kind {
        return switch (self.owner) {
            .node => .attr_node,
            .edge => .attr_edge,
            .graph => .attr_graph,
            .subgraph => .attr_subgraph,
            .cluster => .attr_cluster,
        };
    }
    fn kind(self: *const State) Kind {
        return switch (self.root) {
            .start => .header,
            .strict => .graph_kind,
            .graph => if (self.attributes > 0) (if (self.attribute_valid and self.attribute_phase == .key and self.attributes == 1) self.attributeKind() else .none) else switch (self.mode) {
                .statement, .after_id, .after_scope => .body,
                .endpoint => .endpoint,
                else => .none,
            },
            else => .none,
        };
    }
    fn advance(self: *State, token: dot.lexer.Token, raw: []const u8) void {
        const tag = token.tag;
        if (self.root != .graph) {
            switch (self.root) {
                .start => self.root = switch (tag) {
                    .keyword_strict => .strict,
                    .keyword_graph, .keyword_digraph => .name,
                    else => .bad,
                },
                .strict => self.root = switch (tag) {
                    .keyword_graph, .keyword_digraph => .name,
                    else => .bad,
                },
                .name => if (tag == .identifier) {
                    self.root = .open;
                } else if (tag == .left_brace) {
                    self.root = .graph;
                    self.depth = 1;
                },
                .open => if (tag == .left_brace) {
                    self.root = .graph;
                    self.depth = 1;
                } else {
                    self.root = .bad;
                },
                else => {},
            }
            return;
        }
        if (tag == .left_bracket) {
            self.attribute_valid = self.attributes == 0 and (self.mode == .after_id or self.mode == .attributes);
            self.attributes += 1;
            self.attribute_phase = .key;
            return;
        }
        if (tag == .right_bracket) {
            if (self.attributes > 0) self.attributes -= 1;
            self.mode = .after_id;
            return;
        }
        if (self.attributes > 0) {
            switch (tag) {
                .equals => self.attribute_phase = .value,
                .comma, .semicolon => self.attribute_phase = .key,
                .identifier => self.attribute_phase = if (self.attribute_phase == .value) .key else .equals,
                else => {},
            }
            return;
        }
        switch (tag) {
            .left_brace => {
                if (self.depth >= self.frames.len) {
                    self.root = .bad;
                    return;
                }
                self.frames[self.depth] = .{ .scope = self.scope, .outer = self.owner };
                self.depth += 1;
                self.scope = self.pending_scope;
                self.pending_scope = .subgraph;
                self.owner = .node;
                self.mode = .statement;
            },
            .right_brace => {
                self.depth -= 1;
                if (self.depth == 0) {
                    self.root = .done;
                } else {
                    self.scope = self.frames[self.depth].scope;
                    self.owner = self.frames[self.depth].outer;
                }
                self.mode = .after_scope;
            },
            .semicolon => {
                self.mode = .statement;
                self.owner = .node;
            },
            .edge_directed, .edge_undirected => {
                self.mode = .endpoint;
                self.owner = .edge;
            },
            .colon => self.mode = .port,
            .equals => self.mode = .value,
            .identifier, .keyword_graph, .keyword_digraph, .keyword_strict, .keyword_subgraph, .keyword_node, .keyword_edge => {
                switch (self.mode) {
                    .sub_name => {
                        var decoded: [128]u8 = undefined;
                        const name = if (raw.len > 256) raw else dot.identifier.decodeInto(raw, &decoded) catch raw;
                        self.pending_scope = if (std.mem.startsWith(u8, name, "cluster")) .cluster else .subgraph;
                        self.mode = .sub_open;
                    },
                    .value => self.mode = if (tag == .identifier) .statement else .unknown,
                    .port => self.mode = if (tag == .identifier) .after_id else .unknown,
                    .endpoint => self.mode = if (tag == .keyword_subgraph) .sub_name else if (tag == .identifier) .after_id else .unknown,
                    .statement, .after_id, .after_scope => {
                        self.owner = switch (tag) {
                            .keyword_graph => self.scope,
                            .keyword_edge => .edge,
                            else => .node,
                        };
                        self.mode = switch (tag) {
                            .keyword_subgraph => .sub_name,
                            .keyword_graph, .keyword_node, .keyword_edge => .attributes,
                            .identifier => .after_id,
                            else => .unknown,
                        };
                    },
                    else => self.mode = .unknown,
                }
            },
            else => {},
        }
    }
};
const Builder = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    cancel: *const std.atomic.Value(bool),
    waiting: ?*const std.atomic.Value(usize),
    events: std.ArrayList(u8) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    attribute_keys: attributes.Builder = .{},
    last: u32 = 0,
    kind: Kind = .header,
    count: usize = 0,
    fn deinit(self: *Builder) void {
        self.attribute_keys.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.anchors.deinit(self.gpa);
    }
    fn poll(self: *Builder) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        if (self.waiting) |flag| if (flag.load(.acquire) > 0) return error.Yield;
    }
    fn budget(self: *Builder) !void {
        if (self.attribute_keys.bytes() + self.events.items.len + self.anchors.items.len * @sizeOf(Anchor) > max_bytes) return error.ContextLimit;
    }
    fn emit(self: *Builder, byte: usize, kind: Kind) !void {
        if (kind == self.kind or byte < self.last) return;
        const delta = @as(u32, @intCast(byte)) - self.last;
        if (delta > std.math.maxInt(u32) >> 4) return error.ContextLimit;
        var code: u32 = delta << 4 | @backingInt(kind);
        while (code >= 128) {
            try self.events.append(self.gpa, @as(u8, @intCast(code & 127)) | 128);
            code >>= 7;
        }
        try self.events.append(self.gpa, @intCast(code));
        self.last = @intCast(byte);
        self.kind = kind;
        self.count += 1;
        if (self.count % 128 == 0) try self.anchors.append(self.gpa, .{ .byte = self.last, .cursor = @intCast(self.events.items.len), .kind = kind });
        try self.budget();
    }
    fn gap(self: *Builder, start: usize, end: usize, kind: Kind, preserve_end: bool) !void {
        var reset = true;
        var i = start;
        while (i < end) {
            if (i % 4096 == 0) try self.poll();
            if (self.source[i] == '#' or (self.source[i] == '/' and i + 1 < end and self.source[i + 1] == '/')) {
                try self.emit(i, .none);
                while (i < end and self.source[i] != '\r' and self.source[i] != '\n') : (i += 1) {
                    if (i % 4096 == 0) try self.poll();
                }
                if (i < end) {
                    i += 1;
                    if (self.source[i - 1] == '\r' and i < end and self.source[i] == '\n') i += 1;
                    try self.emit(i, kind);
                }
            } else if (self.source[i] == '/' and i + 1 < end and self.source[i + 1] == '*') {
                try self.emit(i, .none);
                i += 2;
                while (i + 1 < end and !(self.source[i] == '*' and self.source[i + 1] == '/')) : (i += 1) {
                    if (i % 4096 == 0) try self.poll();
                }
                if (i + 1 < end) {
                    i += 2;
                    try self.emit(i, kind);
                } else return;
            } else {
                if (reset) {
                    try self.emit(i + @as(usize, if (preserve_end and i == start) 1 else 0), kind);
                    reset = false;
                }
                i += 1;
            }
        }
    }
    fn scan(self: *Builder) !void {
        try self.anchors.append(self.gpa, .{ .byte = 0, .cursor = 0, .kind = .header });
        var lexer = dot.lexer.For(.block).init(self.source);
        var state: State = .{};
        var end: usize = 0;
        var word = false;
        var previous: ?dot.Span = null;
        while (true) {
            try self.poll();
            const advance = lexer.nextBounded(4096);
            const result = advance.result orelse continue;
            if (result == .failure) {
                const at = @min(lexer.failureDiagnostic().span.start, self.source.len);
                try self.gap(end, @max(end, at), state.kind(), word);
                try self.emit(@max(end, at), .none);
                break;
            }
            const token = result.token;
            const start: usize = token.span.start;
            try self.gap(end, start, state.kind(), word);
            if (token.tag == .eof) {
                break;
            }
            const raw = self.source[start..][0..token.span.len];
            word = switch (token.tag) {
                .identifier, .keyword_graph, .keyword_digraph, .keyword_strict, .keyword_subgraph, .keyword_node, .keyword_edge => true,
                else => false,
            };
            const mask: Kind = if (word and raw[0] != '"' and raw[0] != '<') state.kind() else if (token.tag == .semicolon or token.tag == .right_brace) state.kind() else .none;
            try self.emit(start, mask);
            if (state.root == .graph) {
                if (state.attribute_valid and state.attributes == 1 and state.attribute_phase == .key and token.tag == .identifier) self.attribute_keys.add(self.gpa, token.span, raw);
                if (state.attributes == 0 and state.mode == .after_id and token.tag == .equals) if (previous) |key| self.attribute_keys.add(self.gpa, key, key.slice(self.source));
            }
            previous = if (token.tag == .identifier) token.span else null;
            state.advance(token, raw);
            end = start + token.span.len;
            if (!word) try self.emit(end, state.kind());
        }
    }
};
pub fn build(gpa: std.mem.Allocator, source: []const u8, encoding: pos.Encoding, cancel: *const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Index {
    var builder: Builder = .{ .gpa = gpa, .source = source, .cancel = cancel, .waiting = waiting };
    defer builder.deinit();
    try builder.scan();
    var coordinate_builder: text_coordinates.Builder = .{ .gpa = gpa, .source = source, .cancel = cancel, .waiting = waiting };
    defer coordinate_builder.deinit();
    const other_bytes = builder.attribute_keys.bytes() + builder.events.items.len + builder.anchors.items.len * @sizeOf(Anchor);
    try coordinate_builder.scan(encoding, other_bytes, max_bytes);
    try builder.poll();
    var index: Index = .{};
    errdefer index.deinit(gpa);
    index.events = try builder.events.toOwnedSlice(gpa);
    index.anchors = try builder.anchors.toOwnedSlice(gpa);
    index.coordinates = try coordinate_builder.finish();
    index.attributes = builder.attribute_keys.finish(gpa) catch .{ .available = false };
    return index;
}

test "completion contexts at marked cursor including incomplete input" {
    const cases = .{
        .{ "|", Kind.header },
        .{ "dig|", Kind.header },
        .{ "strict |", Kind.graph_kind },
        .{ "strict dig|", Kind.graph_kind },
        .{ "digraph |", Kind.none },
        .{ "digraph nam|", Kind.none },
        .{ "digraph { |", Kind.body },
        .{ "digraph { nod|", Kind.body },
        .{ "digraph { a -> |", Kind.endpoint },
        .{ "digraph { a -> sub|", Kind.endpoint },
        .{ "digraph { subgraph |", Kind.none },
        .{ "digraph { subgraph name { |", Kind.body },
        .{ "digraph { a [ |", Kind.attr_node },
        .{ "digraph { a [label=|", Kind.none },
        .{ "digraph { a [label=x]; |", Kind.body },
        .{ "digraph { rankdir=|", Kind.none },
        .{ "digraph { a:|", Kind.none },
        .{ "digraph { a:por|", Kind.none },
        .{ "digraph { a:port -> |", Kind.endpoint },
        .{ "digraph { \"nod|e\" }", Kind.none },
        .{ "digraph { \"unfinished|", Kind.none },
        .{ "digraph { a [label=<<B>n|</B>>] }", Kind.none },
        .{ "digraph { // nod|", Kind.none },
        .{ "digraph { a// nod|", Kind.none },
        .{ "digraph { /* nod|", Kind.none },
        .{ "digraph { /* nod */ |", Kind.body },
        .{ "digraph { # nod|", Kind.none },
        .{ "// comment\n|", Kind.header },
        .{ "digraph { // comment\n|", Kind.body },
        .{ "digraph { @ |", Kind.none },
        .{ "digraph { | @", Kind.body },
        .{ "digraph {} |", Kind.none },
        .{ "digraph { a -> { b; | } }", Kind.body },
        .{ "digraph { node |", Kind.none },
    };
    const cancel: std.atomic.Value(bool) = .init(false);
    inline for (cases) |case| {
        const cursor = std.mem.indexOfScalar(u8, case[0], '|').?;
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ case[0][0..cursor], case[0][cursor + 1 ..] });
        defer std.testing.allocator.free(source);
        var coordinates = try pos.Index.init(std.testing.allocator, source);
        defer coordinates.deinit(std.testing.allocator);
        var index = try build(std.testing.allocator, source, .utf16, &cancel, null);
        defer index.deinit(std.testing.allocator);
        const point = try coordinates.positionCancellable(source, cursor, .utf16, &cancel);
        if (index.at(point) != case[1]) std.debug.print("Case {s}: expected {s}, got {s}\n", .{ case[0], @tagName(case[1]), @tagName(index.at(point)) });
        try std.testing.expectEqual(case[1], index.at(point));
    }
}

test "context sparse anchors, Unicode and line endings" {
    const cancel: std.atomic.Value(bool) = .init(false);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "\xef\xbb\xbfdigraph {\r\n");
    for (0..200) |_| try text.appendSlice(std.testing.allocator, "\"😀\" [label=\"é\"]; /* comment */ \r");
    try text.appendSlice(std.testing.allocator, "a -> \n}");
    inline for (.{ pos.Encoding.utf8, .utf16, .utf32 }) |encoding| {
        var coordinates = try pos.Index.init(std.testing.allocator, text.items);
        defer coordinates.deinit(std.testing.allocator);
        var index = try build(std.testing.allocator, text.items, encoding, &cancel, null);
        defer index.deinit(std.testing.allocator);
        try std.testing.expect(index.anchors.len > 1);
        for (text.items, 0..) |byte, i| {
            if (byte == ';') {
                const point = try coordinates.positionCancellable(text.items, i + 1, encoding, &cancel);
                try std.testing.expectEqual(Kind.body, index.at(point));
            }
        }
        try std.testing.expectEqual(Kind.endpoint, index.at(.{ .line = 201, .character = 5 }));
        try std.testing.expectEqual(Kind.none, index.at(.{ .line = 0, .character = 1000 }));
        try std.testing.expectEqual(Kind.none, index.at(.{ .line = 1000, .character = 0 }));
    }
}

test "context cancellation, yielding and allocation failure release storage" {
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, build(std.testing.allocator, "digraph {}", .utf16, &cancel, null));
    cancel.store(false, .release);
    const waiting: std.atomic.Value(usize) = .init(1);
    try std.testing.expectError(error.Yield, build(std.testing.allocator, "digraph {}", .utf16, &cancel, &waiting));
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: std.mem.Allocator) !void {
            const flag: std.atomic.Value(bool) = .init(false);
            var index = try build(gpa, "digraph {\n \"😀\" -> b [label=x];\n}", .utf16, &flag, null);
            defer index.deinit(gpa);
            // Optional hover allocation failure is isolated in production. Expose
            // it to the allocation-failure harness so every allocation is tested.
            if (!index.attributes.available) return error.OutOfMemory;
        }
    }.run, .{});
}
