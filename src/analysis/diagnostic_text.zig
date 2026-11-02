//! Editor wording from typed parser diagnostics. No parsing or heap allocation.
const std = @import("std");
const dot = @import("dot_parser");
const diag = dot.diagnostic;
/// Source-independent collected findings. The job owns slices through its wording
/// arena; protocol borrows these records only while that job remains alive.
pub const Severity = enum(u8) { err, warning, information };
pub const Related = struct { uri: []const u8, range: @import("../text/types.zig").Range, message: []const u8 };
pub const FixToken = struct { generation: u64, index: usize };
pub const Finding = struct {
    fix: ?FixToken = null,
    range: @import("../text/types.zig").Range,
    severity: Severity,
    code: []const u8,
    related: []const Related = &.{},
    message: []const u8,
};
pub const Note = struct { span: dot.Span, message: []const u8 };
pub fn notes(d: dot.Diagnostic, storage: *[2]Note) []const Note {
    var count: usize = 0;
    switch (d.details) {
        .unexpected => |v| {
            if (v.related) |r| {
                storage[count] = .{ .span = r.span, .message = role(r.role) };
                count += 1;
            }
            if (v.suspect) |r| {
                storage[count] = .{ .span = r.span, .message = role(r.role) };
                count += 1;
            }
        },
        .operator_mismatch => |v| {
            storage[0] = .{ .span = v.declaration, .message = "Graph kind declared here." };
            count = 1;
        },
        .repeated_attribute => |span| {
            storage[0] = .{ .span = span, .message = "First occurrence of this attribute." };
            count = 1;
        },
        else => {},
    }
    return storage[0..count];
}
fn role(r: diag.Related.Role) []const u8 {
    return switch (r) {
        .opened_here => "Construct opened here.",
        .suffix_started_here => "Port suffix started here.",
        .declared_here => "Expectation established here.",
        .misindented_close => "Check this closing brace and its enclosing scope.",
    };
}
fn item(v: diag.SyntaxItem) []const u8 {
    return switch (v) {
        .graph_keyword => "'graph'",
        .digraph_keyword => "'digraph'",
        .strict_keyword => "'strict'",
        .subgraph_keyword => "'subgraph'",
        .node_keyword => "'node'",
        .edge_keyword => "'edge'",
        .identifier => "an identifier",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .semicolon => "';'",
        .colon => "':'",
        .undirected_operator => "'--'",
        .directed_operator => "'->'",
        .end_of_input => "end of input",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .equals => "'='",
        .comma => "','",
    };
}
pub fn format(buffer: []u8, d: dot.Diagnostic) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    switch (d.details) {
        .unexpected => |v| {
            const missing_bracket = v.expected.contains(.right_bracket) and (v.found == .right_brace or v.found == .end_of_input);
            const missing_brace = v.expected.contains(.right_brace) and v.found == .end_of_input;
            if (missing_bracket) {
                try out.print("Missing closing ']' before {s}.", .{item(v.found)});
            } else if (missing_brace) {
                try out.writeAll("Missing closing '}' at end of input.");
            } else {
                // Keep the first line useful in narrow inline diagnostics. Details
                // and repairs remain plain text for every LSP client.
                if (v.context == .edge_endpoint) {
                    try out.writeAll("Expected a node name or subgraph");
                } else {
                    try out.writeAll("Expected ");
                    var iter = v.expected.iterator();
                    var first = true;
                    while (iter.next()) |expected| {
                        if (!first) try out.writeAll(" or ");
                        try out.writeAll(item(expected));
                        first = false;
                    }
                    if (first) try out.writeAll("valid DOT syntax");
                }
                try out.print("; found {s}.", .{item(v.found)});
            }
            const help: []const u8 = if (missing_bracket) "Close the attribute list with ']'." else if (missing_brace) "Close the graph or subgraph with '}'." else switch (v.context) {
                .edge_endpoint => "Add a node name or subgraph after the edge operator.",
                .document_header => "Start a graph with 'graph' or 'digraph', followed by an optional name and '{'.",
                .attribute_value, .assignment_value => "Add a value after '='. Use double quotes for text with spaces.",
                .attribute_key => "Add an attribute name before '='.",
                .port_component => "Add a port name or compass point after ':'.",
                .document_epilogue => "Remove the extra token after the graph's closing brace.",
                else => d.code.info().hint,
            };
            if (help.len > 0) try out.print("\n{s}", .{help});
        },
        .reserved_keyword => |v| {
            if (v.context == .attribute_list) {
                try out.print("Keyword '{s}' needs an attribute list beginning with '['.\nIf this is a node name, write it as \"{s}\".", .{ v.keyword.lexeme(), v.keyword.lexeme() });
            } else try out.print("Keyword '{s}' cannot be used as an unquoted name here.\nWrite \"{s}\" to use it as an identifier.", .{ v.keyword.lexeme(), v.keyword.lexeme() });
        },
        .unterminated => |v| try out.writeAll(switch (v) {
            .block_comment => "Unterminated block comment.\nAdd '*/' to close the comment.",
            .quoted_identifier => "Unterminated quoted identifier.\nAdd a closing double quote.",
            .html_identifier => "Unterminated HTML-like identifier.\nClose the outer angle brackets before continuing the DOT statement.",
        }),
        .operator_mismatch => |v| try out.print("Edge operator '{s}' does not match this {s}.\nUse '{s}' here, or change the graph declaration.", .{
            if (v.found == .directed) "->" else "--",
            if (v.expected == .directed) "digraph" else "graph",
            if (v.expected == .directed) "->" else "--",
        }),
        .repeated_attribute => try out.writeAll("This attribute is set more than once in this statement.\nThe later value overrides the earlier value. Check whether this is intentional."),
        .invalid_encoding => try out.writeAll("Invalid UTF-8 sequence in the document.\nSave the document with valid UTF-8 text."),
        .invalid_byte => |v| try out.print("Invalid byte 0x{X:0>2} in DOT syntax.\n{s}", .{ v, d.code.info().hint }),
        .capacity => |v| try out.print("Analysis reached the {s} limit ({d}).\nFurther errors may remain. Reduce nesting or document complexity.", .{ v.resource.name(), v.limit }),
        else => {
            try out.writeAll(d.code.info().summary);
            if (d.code.info().hint.len > 0) try out.print("\n{s}", .{d.code.info().hint});
        },
    }
    return out.buffered();
}
test "expected endpoint uses parser context and includes repair guidance" {
    var buffer: [1536]u8 = undefined;
    const text = try format(&buffer, .{ .code = .syntax_unexpected_token, .span = .{ .start = 0, .len = 1 }, .details = .{ .unexpected = .{ .expected = diag.ExpectedSet.initOne(.identifier), .found = .right_brace, .context = .edge_endpoint } } });
    try std.testing.expect(std.mem.indexOf(u8, text, "found '}'") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after the edge operator") != null);
}
test "related source locations preserve typed parser spans" {
    var storage: [2]Note = undefined;
    const result = notes(.{ .code = .syntax_unexpected_end, .span = .{ .start = 9, .len = 0 }, .details = .{ .unexpected = .{ .expected = diag.ExpectedSet.initOne(.right_brace), .found = .end_of_input, .context = .document_body, .related = .{ .span = .{ .start = 2, .len = 1 }, .role = .opened_here } } } }, &storage);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u32, 2), result[0].span.start);
}
