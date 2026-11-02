//! Syntax core with an optional node-span observer. No I/O or retained syntax.
const std = @import("std");
const dot = @import("dot_parser");
const validation = @import("validation.zig");
pub const Parser = dot.Profile(.{ .policy = @import("parser_policy.zig").dot_ls });
pub const Bag = validation.Bag;
pub const Events = Parser.Events(Consumer);
pub const Scratch = Events.FixedParseScratch(.{ .nesting = 256 });
pub const work_budget = 4096;
// The caller owns source, fixed nesting scratch, sink storage and cancel context.
// No AST is retained. Events feed small, independently bounded collectors.
pub fn run(text: []const u8, scratch: Events.ParseScratch, bag: *Bag, cancellation: dot.Cancellation) dot.events.Result {
    return runIndexed(text, scratch, bag, cancellation, null);
}
pub fn runIndexed(text: []const u8, scratch: Events.ParseScratch, bag: *Bag, cancellation: dot.Cancellation, builder: ?*@import("../features/references.zig").Builder) dot.events.Result {
    return runObserved(text, scratch, bag, cancellation, builder, null);
}
pub fn runObserved(text: []const u8, scratch: Events.ParseScratch, bag: *Bag, cancellation: dot.Cancellation, builder: ?*@import("../features/references.zig").Builder, labels: ?*@import("../features/labels.zig").Collector) dot.events.Result {
    return runOutline(text, scratch, bag, cancellation, builder, labels, null);
}
pub fn runOutline(text: []const u8, scratch: Events.ParseScratch, bag: *Bag, cancellation: dot.Cancellation, builder: ?*@import("../features/references.zig").Builder, labels: ?*@import("../features/labels.zig").Collector, outline: ?*@import("../features/outline.zig").Builder) dot.events.Result {
    var consumer: Consumer = .{ .checks = .{ .source = text, .bag = bag }, .builder = builder, .labels = labels, .outline = outline };
    var session = Events.Session.init(text, scratch, &consumer, bag.sink(), .{ .cancellation = cancellation });
    defer session.deinit();
    while (session.advance(work_budget).result == null) {}
    var result = session.result().?;
    if (result.outcome != .cancelled and !validation.encoding(text, bag, cancellation)) {
        result.outcome = .cancelled;
        result.completion = .incomplete;
    }
    return result;
}
fn neverCancel(_: ?*anyopaque) bool {
    return false;
}
test "syntax analysis is deterministic and retains no tree" {
    var a: Bag = .{};
    var b: Bag = .{};
    var scratch: Scratch = .{};
    const first = run("digraph {a -> }", scratch.storage(), &a, .{ .context = null, .is_requested = neverCancel });
    const second = run("digraph {a -> }", scratch.storage(), &b, .{ .context = null, .is_requested = neverCancel });
    try std.testing.expectEqual(first.outcome, second.outcome);
    try std.testing.expect(a.items().len > 0);
    try std.testing.expectEqual(a.items().len, b.items().len);
    for (a.items(), b.items()) |left, right| {
        try std.testing.expectEqual(left.span, right.span);
        try std.testing.expectEqual(left.code, right.code);
    }
}

test "cooperative cancellation stops syntax analysis" {
    const Cancel = struct {
        polls: usize = 0,
        fn poll(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.polls += 1;
            return self.polls >= 8;
        }
    };
    var cancel: Cancel = .{};
    var bag: Bag = .{};
    var scratch: Scratch = .{};
    const result = run("digraph { a -> b; c -> d; e -> f; }", scratch.storage(), &bag, .{ .context = &cancel, .is_requested = Cancel.poll });
    try std.testing.expect(result.outcome == .cancelled);
}

test "reference allocation failure leaves syntax analysis intact" {
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var cancel: std.atomic.Value(bool) = .init(false);
    const text = "digraph { a -> b }";
    var builder = @import("../features/references.zig").Builder.init(failure.allocator(), text, &cancel);
    defer builder.deinit();
    var bag: Bag = .{};
    var scratch: Scratch = .{};
    const result = runIndexed(text, scratch.storage(), &bag, .{ .context = null, .is_requested = neverCancel }, &builder);
    try std.testing.expect(builder.failed);
    try std.testing.expect(result.outcome == .success);
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
}

test "stream validation agrees with retained validation on operators and logical attribute keys" {
    const sources = [_][]const u8{
        "graph { a -> b; a -- b -> c; {a} -> {b} -- {c} -> {d}; }",
        "digraph { a -- b; a -> b -- c; {a} -- {b} -> {c} -- {d}; }",
        "digraph { a [color=red][\"co\"+\"lor\"=blue]; b [color=red]; node [x=1 x=2]; a -> {b [x=1 x=2]} -> {c [x=3]} [x=1][x=2]; }",
        "graph { a:p -- subgraph x { b:q [a=1 a=2]; } -- c; color=red; color=blue; }",
        "digraph { a [\"a\\\"b\"=1][\"a\\\"b\"=2]; a [\"c\"+/* glue */\"olor\"=red color=blue]; }",
    };
    for (sources) |source| {
        var expected: dot.FixedDiagnosticBag(1000) = .{};
        var keys: [64]dot.AttributeKeyScratch = undefined;
        var parsed = Parser.parseAndValidate(std.testing.allocator, source, expected.sink(), .{
            .validation = .{ .attribute_keys = &keys },
            .cancellation = .{ .context = null, .is_requested = neverCancel },
        });
        defer parsed.deinit(std.testing.allocator);
        var actual: Bag = .{};
        var scratch: Scratch = .{};
        const result = run(source, scratch.storage(), &actual, .{ .context = null, .is_requested = neverCancel });
        try std.testing.expect(result.outcome == .success);
        try std.testing.expect(!actual.incomplete);
        try std.testing.expectEqual(expected.items().len, actual.items().len);
        for (expected.items()) |e| {
            var matches: usize = 0;
            for (actual.items()) |a| if (a.code == e.code and std.meta.eql(a.span, e.span)) {
                matches += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }
}

test "bounded duplicate checking reports incomplete and resets for the next owner" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("digraph { a [");
    for (0..300) |i| try source.writer.print("k{d}=x ", .{i});
    try source.writer.writeAll("]; b [x=1 x=2]; }");
    var bag: Bag = .{};
    var scratch: Scratch = .{};
    const result = run(source.written(), scratch.storage(), &bag, .{ .context = null, .is_requested = neverCancel });
    try std.testing.expect(result.outcome == .success);
    try std.testing.expect(bag.incomplete);
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    try std.testing.expect(bag.items()[0].code == .validation_repeated_attribute_tolerated);
}

test "encoding validation covers comments strings and HTML and can cancel" {
    const sources = [_][]const u8{ "digraph { // \xff\n a; }", "digraph { a [label=\"\xff\"]; }", "digraph { a [label=<<B>\xff</B>>]; }", "digraph { /* \xc0\xaf */ a; }" };
    for (sources) |source| {
        var bag: Bag = .{};
        try std.testing.expect(validation.encoding(source, &bag, .{ .context = null, .is_requested = neverCancel }));
        try std.testing.expect(bag.items().len > 0);
        try std.testing.expect(bag.items()[0].code == .validation_invalid_encoding);
    }
    var bag: Bag = .{};
    try std.testing.expect(validation.encoding("digraph { \"é😀\"; }", &bag, .{ .context = null, .is_requested = neverCancel }));
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
    const Cancel = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    try std.testing.expect(!validation.encoding("digraph {}", &bag, .{ .context = null, .is_requested = Cancel.poll }));
}

test "cancellation during the source scan prevents completed results" {
    const Cancel = struct {
        checks: usize = 0,
        stop_at: usize = std.math.maxInt(usize),
        fn poll(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.checks += 1;
            return self.checks >= self.stop_at;
        }
    };
    const source = "digraph { a -> b; }";
    var counter: Cancel = .{};
    var scratch: Scratch = .{};
    var parser_bag: dot.FixedDiagnosticBag(1000) = .{};
    var check_bag: Bag = .{};
    var consumer: Consumer = .{ .checks = .{ .source = source, .bag = &check_bag } };
    var session = Events.Session.init(source, scratch.storage(), &consumer, parser_bag.sink(), .{ .cancellation = .{ .context = &counter, .is_requested = Cancel.poll } });
    defer session.deinit();
    while (session.advance(work_budget).result == null) {}
    try std.testing.expect(session.result().?.outcome == .success);
    var cancel: Cancel = .{ .stop_at = counter.checks + 1 };
    var bag: Bag = .{};
    const result = run(source, scratch.storage(), &bag, .{ .context = &cancel, .is_requested = Cancel.poll });
    try std.testing.expect(result.outcome == .cancelled);
    try std.testing.expect(result.completion == .incomplete);
}

test "outline allocation failure does not change syntax diagnostics" {
    const text = "digraph G { a; broken -> ; b; }";
    var builder: @import("../features/outline.zig").Builder = .{ .allocator = std.testing.failing_allocator, .source = text };
    defer builder.deinit();
    var expected: Bag = .{};
    var actual: Bag = .{};
    var scratch: Scratch = .{};
    const plain = run(text, scratch.storage(), &expected, .{ .context = null, .is_requested = neverCancel });
    const outlined = runOutline(text, scratch.storage(), &actual, .{ .context = null, .is_requested = neverCancel }, null, null, &builder);
    try std.testing.expect(builder.failed);
    try std.testing.expectEqual(plain.outcome, outlined.outcome);
    try std.testing.expectEqualDeep(expected.items(), actual.items());
}

const Consumer = struct {
    pub const statement_extents = true;
    pub const observations: dot.events.Observations = .{ .statement_head = true, .delimiter = true };
    checks: validation.State,
    builder: ?*@import("../features/references.zig").Builder = null,
    labels: ?*@import("../features/labels.zig").Collector = null,
    outline: ?*@import("../features/outline.zig").Builder = null,
    pub fn onAbort(self: *@This(), event: dot.events.Abort) void {
        if (self.outline) |o| {
            const findings = self.checks.bag.items();
            const node_eof = findings.len > 0 and switch (findings[findings.len - 1].details) {
                .unexpected => |u| u.found == .end_of_input and u.context == .statement,
                else => false,
            };
            o.abort(event, node_eof);
        }
        self.checks.clearStatement();
    }
    pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
        validation.State.emit(&self.checks, event);
        if (self.outline) |o| @import("../features/outline.zig").Builder.observe(o, event);
        switch (event) {
            .commit_node => |v| {
                if (self.builder) |b| @import("../features/references.zig").Builder.emit(b, v.value.identifier);
            },
            .commit_edge, .commit_edge_chain => |v| if (self.builder) |b| {
                if (v.value.leftName()) |name| @import("../features/references.zig").Builder.emit(b, name);
                if (v.value.rightName()) |name| @import("../features/references.zig").Builder.emit(b, name);
            },
            .edge_link => |v| if (self.builder) |b| @import("../features/references.zig").Builder.emit(b, v.link.right),
            .attribute => |v| if (self.labels) |l| @import("../features/labels.zig").Collector.emit(l, v.pair.key, v.pair.value),
            .commit_assignment => |v| if (self.labels) |l| @import("../features/labels.zig").Collector.emit(l, v.value.key, v.value.value),
            else => {},
        }
        return .proceed;
    }
};
