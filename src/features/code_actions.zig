//! Compact parser fix offers. No source, syntax tree, or diagnostic text retained.
const std = @import("std");
const dot = @import("dot_parser");
const pos = @import("../text/positions.zig");
pub const Range = @import("../text/types.zig").Range;
const Point = struct {
    line: u32,
    character: u32,
    fn from(p: pos.Position) Point {
        return .{ .line = @intCast(p.line), .character = @intCast(p.character) };
    }
    fn wire(p: Point) pos.Position {
        return .{ .line = p.line, .character = p.character };
    }
};
const CompactRange = struct {
    start: Point,
    end: Point,
    fn from(r: Range) CompactRange {
        return .{ .start = Point.from(r.start), .end = Point.from(r.end) };
    }
    pub fn wire(r: CompactRange) Range {
        return .{ .start = r.start.wire(), .end = r.end.wire() };
    }
};
pub const Edit = struct { range: Range, text: []const u8 };
pub const Fix = struct {
    diagnostic: CompactRange,
    edit: CompactRange,
    kind: enum(u8) { insert, replace, delete, quote },
    replacement: dot.diagnostic.Replacement = .semicolon,
    preferred: bool,
    pub fn capture(parser_fix: anytype, diagnostic: Range, diagnostic_span: dot.Span, source: []const u8, origin: u32, index: pos.Index, encoding: pos.Encoding, cancel: *const std.atomic.Value(bool), waiting: ?*const std.atomic.Value(usize)) !Fix {
        const span = parser_fix.span;
        const begin = @as(usize, origin) + span.start;
        const end = begin + span.len;
        if (end > source.len) return error.InvalidFixSpan;
        var first = begin;
        var last = end;
        var kind: @FieldType(Fix, "kind") = undefined;
        var replacement: dot.diagnostic.Replacement = .semicolon;
        switch (parser_fix.edit) {
            .delete => kind = .delete,
            .wrap_in_quotes => kind = .quote,
            .replace => |r| {
                kind = .replace;
                replacement = replacementOf(r);
            },
            .insert_before => |r| {
                kind = .insert;
                last = first;
                replacement = replacementOf(r);
            },
            .insert_after => |r| {
                kind = .insert;
                first = last;
                replacement = replacementOf(r);
            },
        }
        // Most fixes use the diagnostic's own span. Reuse its converted
        // positions, especially for errors near the end of very long lines.
        const diagnostic_start = @as(usize, origin) + diagnostic_span.start;
        const diagnostic_end = diagnostic_start + diagnostic_span.len;
        return .{ .diagnostic = CompactRange.from(diagnostic), .edit = CompactRange.from(.{
            .start = if (first == diagnostic_start) diagnostic.start else if (first == diagnostic_end) diagnostic.end else if (waiting != null) try index.positionBackground(source, first, encoding, cancel, waiting) else try index.positionCancellable(source, first, encoding, cancel),
            .end = if (last == diagnostic_end) diagnostic.end else if (last == diagnostic_start) diagnostic.start else if (waiting != null) try index.positionBackground(source, last, encoding, cancel, waiting) else try index.positionCancellable(source, last, encoding, cancel),
        }), .kind = kind, .replacement = replacement, .preferred = parser_fix.applicability == .machine_applicable };
    }
    pub fn title(self: Fix, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.kind) {
            .delete => "Remove unexpected text",
            .quote => "Put double quotes around this name",
            .insert => switch (self.replacement) {
                .right_bracket => "Insert closing ']'",
                .right_brace => "Insert closing '}'",
                .comment_close => "Close the block comment with '*/'",
                else => try std.fmt.allocPrint(allocator, "Insert '{s}'", .{self.replacement.text()}),
            },
            .replace => try std.fmt.allocPrint(allocator, "Replace with '{s}'", .{self.replacement.text()}),
        };
    }
    pub fn edits(self: Fix, storage: *[2]Edit) []const Edit {
        const range = self.edit.wire();
        if (self.kind == .quote) {
            storage.* = .{ .{ .range = .{ .start = range.start, .end = range.start }, .text = "\"" }, .{ .range = .{ .start = range.end, .end = range.end }, .text = "\"" } };
            return storage;
        }
        storage[0] = .{ .range = range, .text = if (self.kind == .delete) "" else self.replacement.text() };
        return storage[0..1];
    }
    pub fn touches(self: Fix, range: Range) bool {
        const d = self.diagnostic.wire();
        return !before(d.end, range.start) and !before(range.end, d.start);
    }
};
pub fn before(a: pos.Position, b: pos.Position) bool {
    return a.line < b.line or (a.line == b.line and a.character < b.character);
}
test "fix records stay small and quotation inserts do not copy source" {
    try std.testing.expect(@sizeOf(Fix) <= 40);
    const f: Fix = .{ .diagnostic = CompactRange.from(.{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 6 } }), .edit = CompactRange.from(.{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 6 } }), .kind = .quote, .preferred = true };
    var storage: [2]Edit = undefined;
    const edits = f.edits(&storage);
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqual(@as(usize, 6), edits[1].range.start.character);
    try std.testing.expectEqualStrings("\"", edits[0].text);
}

fn replacementOf(r: anytype) dot.diagnostic.Replacement {
    return switch (r) {
        inline else => |value| @field(dot.diagnostic.Replacement, @tagName(value)),
    };
}
