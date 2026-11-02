const std = @import("std");
const dot = @import("dot_parser");
const Sink = struct {
    events: usize = 0,
    aborts: usize = 0,
    hash: u64 = 0,
    pub fn onEvent(self: *@This(), e: dot.events.Event) error{}!dot.events.Action {
        self.events += 1;
        self.hash = self.hash *% 31 +% @backingInt(std.meta.activeTag(e));
        return .proceed;
    }
    pub fn onAbort(self: *@This(), _: dot.events.Abort) void {
        self.aborts += 1;
    }
};
fn noCancel(_: ?*anyopaque) bool {
    return false;
}
test "public event sessions preserve results and events across budgets and prefixes" {
    const fixture = "digraph G { a:p -> { b; c -> d } -> e [label=<B>] broken -> ; later; }";
    inline for (.{ .scalar, .block }) |scanner| {
        const E = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true, .cancellation = true } } }).Events(Sink);
        for (0..fixture.len + 1) |len| {
            var expected_sink: Sink = .{};
            var expected_bag: dot.FixedDiagnosticBag(128) = .{};
            var scratch: E.FixedParseScratch(.{ .nesting = 8 }) = .{};
            const expected = E.parseIn(fixture[0..len], scratch.storage(), &expected_sink, expected_bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
            for ([_]usize{ 1, 17, 4096 }) |budget| {
                var sink: Sink = .{};
                var bag: dot.FixedDiagnosticBag(128) = .{};
                var session = E.Session.init(fixture[0..len], scratch.storage(), &sink, bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
                defer session.deinit();
                try std.testing.expectEqual(@as(usize, 0), session.advance(0).work_used);
                while (true) {
                    const step = session.advance(budget);
                    try std.testing.expect(step.work_used <= budget);
                    if (step.result != null) break;
                }
                try std.testing.expectEqualDeep(expected, session.result().?);
                try std.testing.expectEqualDeep(expected_sink, sink);
                try std.testing.expectEqualDeep(expected_bag.items(), bag.items());
            }
        }
    }
}
test "public event session cancellation reset and exhausted scratch are explicit" {
    const E = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } }).Events(Sink);
    var scratch: E.FixedParseScratch(.{ .nesting = 1 }) = .{};
    var sink: Sink = .{};
    var bag: dot.FixedDiagnosticBag(128) = .{};
    var session = E.Session.init("digraph { a -> b; }", scratch.storage(), &sink, bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
    defer session.deinit();
    _ = session.advance(1);
    try std.testing.expect(session.cancel().outcome == .cancelled);
    sink = .{};
    session.reset("digraph { { { a; } } }", &sink, bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
    try std.testing.expect(session.run().outcome == .storage_failure);
}

test "public outline observations preserve diagnostics and bounded progress" {
    const outline = @import("../features/outline.zig");
    const Observer = struct {
        pub const statement_extents = true;
        pub const observations: dot.events.Observations = .{ .statement_head = true, .delimiter = true };
        normal: Sink = .{},
        builder: *outline.Builder,
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            outline.Builder.observe(self.builder, event);
            return switch (event) {
                .statement_head, .delimiter => .proceed,
                else => self.normal.onEvent(event),
            };
        }
        pub fn onAbort(self: *@This(), event: dot.events.Abort) void {
            self.builder.abort(event, false);
            self.normal.onAbort(event);
        }
    };
    const source = "digraph G { a [x=; b; }";
    const policy: dot.Policy = .{ .execution = .{ .metering = true, .cancellation = true } };
    const E = dot.Profile(.{ .policy = policy }).Events(Observer);
    const Plain = dot.Profile(.{ .policy = policy }).Events(Sink);
    var plain: Sink = .{};
    var plain_bag: dot.FixedDiagnosticBag(128) = .{};
    var plain_scratch: Plain.FixedParseScratch(.{ .nesting = 8 }) = .{};
    const expected = Plain.parseIn(source, plain_scratch.storage(), &plain, plain_bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
    for ([_]usize{ 1, 17, 4096 }) |budget| {
        var builder: outline.Builder = .{ .allocator = std.testing.allocator, .source = source };
        defer builder.deinit();
        var sink: Observer = .{ .builder = &builder };
        var bag: dot.FixedDiagnosticBag(128) = .{};
        var scratch: E.FixedParseScratch(.{ .nesting = 8 }) = .{};
        var session = E.Session.init(source, scratch.storage(), &sink, bag.sink(), .{ .cancellation = .{ .context = null, .is_requested = noCancel } });
        defer session.deinit();
        while (true) {
            const progress = session.advance(budget);
            try std.testing.expect(progress.work_used <= budget);
            if (progress.result != null) break;
        }
        try std.testing.expectEqualDeep(expected, session.result().?);
        try std.testing.expectEqualDeep(plain, sink.normal);
        try std.testing.expectEqualDeep(plain_bag.items(), bag.items());
        try std.testing.expectEqual(@as(usize, 3), builder.raw.items.len);
        try std.testing.expectEqualStrings("a", builder.raw.items[1].name.slice(source));
        try std.testing.expectEqualStrings("b", builder.raw.items[2].name.slice(source));
        try std.testing.expectEqual(source.len, builder.raw.items[0].end);
    }
}

test "trusted identifier helpers agree with checked helpers for parsed spellings" {
    const names = [_][]const u8{ "a", "12", "\"a\"", "\"a\"+/*glue*/\"b\"", "\"é😀\"", "\"a\\\"b\"", "<B>" };
    for (names) |a| {
        const parsed_a = dot.identifier.fromName(a, try dot.identifier.check(a, .{ .start = 0, .len = @intCast(a.len) }));
        try std.testing.expectEqual(try dot.identifier.hash(a), try parsed_a.hash());
        for (names) |b| {
            const parsed_b = dot.identifier.fromName(b, try dot.identifier.check(b, .{ .start = 0, .len = @intCast(b.len) }));
            try std.testing.expectEqual(try dot.identifier.eql(a, b), try parsed_a.eql(parsed_b));
        }
    }
}
