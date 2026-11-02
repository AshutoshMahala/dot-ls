//! Streaming DOT checks. No AST, allocations, or document-sized validation index.
const std = @import("std");
const dot = @import("dot_parser");
const rules = @import("parser_policy.zig");
const policy = rules.dot_ls;
pub const Bag = struct {
    storage: dot.FixedDiagnosticBag(1000) = .{},
    incomplete: bool = false,
    full: bool = false,
    pub fn items(self: *const Bag) []const dot.Diagnostic {
        return self.storage.items();
    }
    pub fn sink(self: *Bag) dot.DiagnosticSink {
        return .{ .context = self, .emit_fn = emit };
    }
    fn emit(context: ?*anyopaque, d: dot.Diagnostic) dot.DiagnosticSinkError!dot.DiagnosticAction {
        const self: *Bag = @ptrCast(@alignCast(context.?));
        if (self.full) return .stop;
        const action = try self.storage.push(d);
        if (action == .stop) {
            self.full = true;
            self.incomplete = true;
        }
        return action;
    }
    fn add(self: *Bag, d: dot.Diagnostic) void {
        _ = self.sink().emit(d) catch {
            self.incomplete = true;
        };
    }
};
const Entry = struct { hash: u64 = 0, name: dot.Name = .{ .start = 0, .len = 0 }, generation: u32 = 0 };
pub const State = struct {
    source: []const u8,
    bag: *Bag,
    header: dot.Span = .{ .start = 0, .len = 0 },
    directed: bool = false,
    entries: [512]Entry = @splat(.{}),
    generation: u32 = 1,
    keys: usize = 0,
    pub fn clearStatement(self: *State) void {
        self.keys = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            self.entries = @splat(.{});
            self.generation = 1;
        }
    }
    pub fn emit(context: *anyopaque, event: dot.events.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.bag.full) return;
        switch (event) {
            .begin_document => |v| {
                self.header = v.keyword_span;
                self.directed = v.kind == .digraph;
            },
            .attribute => |v| self.attribute(v.pair.key),
            .commit_edge, .commit_edge_chain => |e| {
                const v = e.value;
                self.operator(v.operator == .directed, v.operator_span);
                self.clearStatement();
            },
            .edge_link => |v| self.operator(v.link.operator == .directed, v.link.operator_span),
            .begin_scope => |v| {
                if (v.link_operator) |op| self.operator(op == .directed, v.link_operator_span.?);
                self.clearStatement();
            },
            .commit_node, .commit_attribute_statement, .commit_assignment, .end_scope, .commit_subgraph => self.clearStatement(),
            else => {},
        }
    }
    fn operator(self: *State, directed: bool, span: dot.Span) void {
        const setting = if (self.directed) policy.validation.digraph.operator_mismatch.? else policy.validation.graph.operator_mismatch.?;
        if (setting == .off or directed == self.directed) return;
        self.bag.add(.{ .code = if (setting == .err) .validation_operator_mismatch else .validation_operator_tolerated, .span = span, .details = .{ .operator_mismatch = .{
            .expected = if (self.directed) .directed else .undirected,
            .found = if (directed) .directed else .undirected,
            .declaration = self.header,
            .reading = .as_written,
            .kind_overridden = false,
            .suggest_header_change = true,
        } }, .fix = .{ .span = span, .edit = .{ .replace = if (self.directed) .directed_operator else .undirected_operator }, .applicability = .maybe } });
    }
    fn attribute(self: *State, name: dot.Name) void {
        const span = name.span();
        if (policy.validation.repeated_attribute.? == .off) return;
        if (span.len > rules.max_key_bytes) {
            self.bag.incomplete = true;
            return;
        }
        const parsed = dot.identifier.fromName(self.source, name);
        const hash = (parsed.hash() catch unreachable);
        var slot: usize = @intCast(hash & 511);
        for (0..rules.max_key_probes) |_| {
            const entry = &self.entries[slot];
            if (entry.generation != self.generation) {
                if (self.keys == rules.max_attribute_keys) {
                    self.bag.incomplete = true;
                    return;
                }
                entry.* = .{ .hash = hash, .name = name, .generation = self.generation };
                self.keys += 1;
                return;
            }
            if (entry.hash == hash and (dot.identifier.fromName(self.source, entry.name).eql(parsed) catch unreachable)) {
                self.bag.add(.{ .code = if (policy.validation.repeated_attribute.? == .err) .validation_repeated_attribute else .validation_repeated_attribute_tolerated, .span = span, .details = .{ .repeated_attribute = entry.name.span() } });
                return;
            }
            slot = (slot + 1) & 511;
        }
        self.bag.incomplete = true;
    }
};
/// Encoding is a source property, including comments and HTML. ASCII blocks
/// bypass scalar decoding. Poll between bounded chunks, including long tokens.
pub fn encoding(source: []const u8, bag: *Bag, cancellation: dot.Cancellation) bool {
    if (policy.validation.invalid_encoding.? == .off) return true;
    var at: u32 = 0;
    while (at < source.len) {
        if (cancellation.is_requested(cancellation.context)) return false;
        const end = @min(source.len, @as(usize, at) + 4096);
        while (at < end) {
            if (end - at >= 32) {
                const bytes: @Vector(32, u8) = source[at..][0..32].*;
                if (@reduce(.Max, bytes) < 128) {
                    at += 32;
                    continue;
                }
            }
            const step = dot.encoding.validationStep(.utf8, source, at);
            if (step.invalid) |invalid| bag.add(.{ .code = .validation_invalid_encoding, .span = .{ .start = at, .len = 1 }, .details = .{ .invalid_encoding = invalid } });
            at += step.len;
            if (bag.full) return true;
        }
    }
    return true;
}
