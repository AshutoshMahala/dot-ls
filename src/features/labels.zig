//! Parser-selected HTML labels, delayed checks and exact-content result reuse.
const std = @import("std");
const dot = @import("dot_parser");
pub const markup = @import("markup_parser");
const Profile = markup.Profile(.{ .policy = policy });
const policy = blk: {
    var p = markup.presets.untrusted;
    p.mode = .graphviz;
    // Preserve structural checking during the dependency update. Select the
    // newer Graphviz vocabulary/content/value rules as a separate feature.
    p.validation.graphviz = .{ .unknown_element = .off, .invalid_attribute = .off, .invalid_content = .off, .invalid_value = .off, .unknown_reference = .off };
    p.scanner = .block;
    p.execution = .{ .metering = true, .cancellation = true };
    break :blk p;
};
pub const max_cache_bytes = 8 * 1024 * 1024;
pub const max_entries = 4096;
/// Ordered spans encoded as unsigned varints: gap after the previous body, length.
/// A selected attribute needs at least eight source bytes (label=<>). Gap and
/// length varints fit in one quarter of the source, plus first-record allowance.
pub const Spans = struct {
    encoded: std.ArrayList(u8) = .empty,
    count: usize = 0,
    end: u32 = 0,
    pub fn deinit(self: *Spans, gpa: std.mem.Allocator) void {
        self.encoded.deinit(gpa);
    }
    fn encode(buffer: []u8, input: u32) usize {
        var value = input;
        var used: usize = 0;
        while (true) {
            buffer[used] = @as(u8, @intCast(value & 127)) | (if (value >= 128) @as(u8, 128) else 0);
            used += 1;
            value >>= 7;
            if (value == 0) return used;
        }
    }
    pub fn append(self: *Spans, gpa: std.mem.Allocator, span: dot.Span, limit: usize) !void {
        if (span.start < self.end) return error.UnorderedLabelSpan;
        const end = @addWithOverflow(span.start, span.len);
        if (end[1] != 0) return error.LabelSpanOverflow;
        var bytes: [10]u8 = undefined;
        const gap_len = encode(&bytes, span.start - self.end);
        const len = gap_len + encode(bytes[gap_len..], span.len);
        if (len > limit -| self.encoded.items.len) return error.LabelSpanBudget;
        const needed = self.encoded.items.len + len;
        if (needed > self.encoded.capacity) {
            // Bound capacity as well as used bytes; no oversized geometric reserve.
            try self.encoded.ensureTotalCapacityPrecise(gpa, @min(limit, @max(needed, self.encoded.capacity + self.encoded.capacity / 2 + 64)));
        }
        self.encoded.appendSliceAssumeCapacity(bytes[0..len]);
        self.count += 1;
        self.end = end[0];
    }
    pub const Iterator = struct {
        offset: usize = 0,
        end: u32 = 0,
        fn decode(self: *Iterator, bytes: []const u8) u32 {
            var value: u32 = 0;
            var shift: u5 = 0;
            while (true) {
                const byte = bytes[self.offset];
                self.offset += 1;
                value |= @as(u32, byte & 127) << shift;
                if (byte < 128) return value;
                shift += 7;
            }
        }
        pub fn next(self: *Iterator, spans: *const Spans) ?dot.Span {
            if (self.offset == spans.encoded.items.len) return null;
            const start = self.end + self.decode(spans.encoded.items);
            const len = self.decode(spans.encoded.items);
            self.end = start + len;
            return .{ .start = start, .len = len };
        }
    };
};
pub const Collector = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    spans: Spans = .{},
    incomplete: bool = false,
    pub fn deinit(self: *Collector) void {
        self.spans.deinit(self.allocator);
    }
    pub fn add(self: *Collector, span: dot.Span) !void {
        try self.spans.append(self.allocator, span, self.source.len / 4 + 16);
    }
    pub fn emit(ctx: *anyopaque, key: dot.Name, value: dot.Name) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        if (self.incomplete or value.len < 2 or self.source[value.start] != '<') return;
        const parsed = dot.identifier.fromName(self.source, key);
        var selected = false;
        inline for (.{ "label", "xlabel", "headlabel", "taillabel" }) |name| {
            const target = dot.identifier.check(name, .{ .start = 0, .len = name.len }) catch unreachable;
            if ((parsed.eql(dot.identifier.fromName(name, target)) catch unreachable)) selected = true;
        }
        if (!selected) return;
        // DOT's wrapper is not part of the embedded markup fragment.
        self.add(.{ .start = value.start + 1, .len = value.len - 2 }) catch {
            self.incomplete = true;
        };
    }
};
/// Counts live retained payload across published and in-flight cache generations.
pub const Budget = struct {
    live: std.atomic.Value(usize) = .init(0),
    entries: std.atomic.Value(usize) = .init(0),
    pub const limit = 32 * 1024 * 1024;
    fn reserve(self: *Budget, bytes: usize) bool {
        var old = self.live.load(.monotonic);
        while (true) {
            if (bytes > limit - old) return false;
            old = self.live.cmpxchgWeak(old, old + bytes, .acq_rel, .monotonic) orelse break;
        }
        if (self.entries.fetchAdd(1, .acq_rel) >= 16384) {
            _ = self.entries.fetchSub(1, .release);
            _ = self.live.fetchSub(bytes, .release);
            return false;
        }
        return true;
    }
    fn release(self: *Budget, bytes: usize) void {
        _ = self.live.fetchSub(bytes, .release);
        _ = self.entries.fetchSub(1, .release);
    }
};
const Entry = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    budget: ?*Budget = null,
    text: []u8,
    diagnostics: []markup.Diagnostic,
    incomplete: bool,
    fn bytes(self: *const Entry) usize {
        return @sizeOf(Entry) + self.text.len + self.diagnostics.len * @sizeOf(markup.Diagnostic);
    }
    fn retain(self: *Entry) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Entry, _: std.mem.Allocator) void {
        const gpa = self.allocator;
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.budget) |budget| budget.release(self.bytes());
        gpa.free(self.text);
        gpa.free(self.diagnostics);
        gpa.destroy(self);
    }
};
pub const Cache = struct {
    refs: std.atomic.Value(usize) = .init(1),
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    payload_bytes: usize = 0,
    pub fn create(gpa: std.mem.Allocator) !*Cache {
        const self = try gpa.create(Cache);
        self.* = .{};
        return self;
    }
    pub fn retain(self: *Cache) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Cache, gpa: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.*.release(gpa);
        self.entries.deinit(gpa);
        gpa.destroy(self);
    }
    fn add(self: *Cache, gpa: std.mem.Allocator, entry: *Entry, budget: ?*Budget) !bool {
        if (self.entries.count() == max_entries or entry.bytes() > max_cache_bytes - self.payload_bytes) return false;
        var charged = false;
        if (entry.budget == null) if (budget) |global| {
            if (!global.reserve(entry.bytes())) return false;
            entry.budget = global;
            charged = true;
        };
        errdefer if (charged) {
            entry.budget.?.release(entry.bytes());
            entry.budget = null;
        };
        try self.entries.put(gpa, entry.text, entry);
        entry.retain();
        self.payload_bytes += entry.bytes();
        return true;
    }
};
pub const Located = struct { origin: u32, diagnostic: markup.Diagnostic };
const Hook = struct {
    cancel: *const std.atomic.Value(bool),
    waiting: *const std.atomic.Value(usize),
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Hook = @ptrCast(@alignCast(ctx.?));
        return self.cancel.load(.acquire) or self.waiting.load(.acquire) != 0;
    }
};
fn check(gpa: std.mem.Allocator, text: []const u8, hook: *Hook) !*Entry {
    var bag: markup.FixedDiagnosticBag(64) = .{};
    var scratch: markup.FixedParseScratch(256) = .{};
    const options: Profile.Options = .{ .cancellation = markup.Cancellation{ .context = hook, .is_requested = Hook.requested } };
    const parsed = Profile.measureIn(text, scratch.storage(), bag.sink(), options);
    var incomplete = parsed.completion != .complete;
    if (parsed.outcome == .cancelled) return error.Interrupted;
    if (parsed.completion == .complete) {
        var validation_scratch: markup.FixedSourceValidationScratch(1024) = .{};
        const result = Profile.validateSourceIn(text, validation_scratch.storage(), bag.sink(), options);
        if (Hook.requested(hook)) return error.Interrupted;
        incomplete = incomplete or result.completion != .complete;
    }
    if (Hook.requested(hook)) return error.Interrupted;
    const entry = try gpa.create(Entry);
    errdefer gpa.destroy(entry);
    const copy = try gpa.dupe(u8, if (text.len > max_cache_bytes) "" else text);
    errdefer gpa.free(copy);
    entry.* = .{ .allocator = gpa, .text = copy, .diagnostics = try gpa.dupe(markup.Diagnostic, bag.items()), .incomplete = incomplete };
    return entry;
}
pub const Work = struct {
    entry_allocator: ?std.mem.Allocator = null,
    budget: ?*Budget = null,
    allocator: std.mem.Allocator,
    cache: ?*Cache,
    diagnostics: std.ArrayList(Located) = .empty,
    cursor: usize = 0,
    positions: Spans.Iterator = .{},
    checked: usize = 0,
    reused: usize = 0,
    incomplete: bool = false,
    pub fn init(gpa: std.mem.Allocator) !Work {
        return .{ .allocator = gpa, .cache = try Cache.create(gpa) };
    }
    pub fn deinit(self: *Work) void {
        if (self.cache) |cache| cache.release(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }
    /// False yields to new DOT work. Complete labels survive a yield.
    pub fn advance(self: *Work, collector: *const Collector, previous: ?*Cache, cancel: *const std.atomic.Value(bool), waiting: *const std.atomic.Value(usize)) !bool {
        var hook: Hook = .{ .cancel = cancel, .waiting = waiting };
        while (self.cursor < collector.spans.count) {
            if (cancel.load(.acquire)) return error.Cancelled;
            if (waiting.load(.acquire) != 0) return false;
            var next = self.positions;
            const span = next.next(&collector.spans).?;
            const text = collector.source[span.start..][0..span.len];
            const current = self.cache.?.entries.get(text);
            const cached = current orelse if (previous) |old| old.entries.get(text) else null;
            var owned: ?*Entry = null;
            defer if (owned) |entry| entry.release(self.allocator);
            const entry = cached orelse blk: {
                const fresh = check(self.entry_allocator orelse self.allocator, text, &hook) catch |err| {
                    if (err == error.Interrupted) {
                        if (cancel.load(.acquire)) return error.Cancelled;
                        return false;
                    }
                    return err;
                };
                owned = fresh;
                self.checked += 1;
                break :blk fresh;
            };
            if (cached != null) self.reused += 1;
            if (entry.text.len == text.len and current == null) _ = try self.cache.?.add(self.allocator, entry, self.budget);
            self.incomplete = self.incomplete or entry.incomplete;
            for (entry.diagnostics) |d| {
                if (self.diagnostics.items.len == 1000) {
                    self.incomplete = true;
                    break;
                }
                try self.diagnostics.append(self.allocator, .{ .origin = span.start, .diagnostic = d });
            }
            self.positions = next;
            self.cursor += 1;
            if (self.diagnostics.items.len == 1000) {
                self.incomplete = true;
                self.cursor = collector.spans.count;
            }
        }
        self.incomplete = self.incomplete or collector.incomplete;
        return true;
    }
};

test "only parser-recognized HTML label positions are selected" {
    var collector: Collector = .{ .allocator = std.testing.allocator, .source = "label=<x>; label=\"quoted\"; other=<x>; \"la\"+\"bel\"=<x>" };
    defer collector.deinit();
    Collector.emit(&collector, .{ .start = 0, .len = 5 }, .{ .start = 6, .len = 3 });
    Collector.emit(&collector, .{ .start = 11, .len = 5 }, .{ .start = 17, .len = 8 });
    Collector.emit(&collector, .{ .start = 27, .len = 5 }, .{ .start = 33, .len = 3 });
    Collector.emit(&collector, .{ .start = 38, .len = 10 }, .{ .start = 49, .len = 3 });
    try std.testing.expectEqual(@as(usize, 2), collector.spans.count);
}

test "delayed checks reuse exact HTML bytes, share duplicates and keep local spans" {
    const gpa = std.testing.allocator;
    const cancel: std.atomic.Value(bool) = .init(false);
    var waiting: std.atomic.Value(usize) = .init(0);
    var collector: Collector = .{ .allocator = gpa, .source = "<B>x</I><B>x</I>" };
    defer collector.deinit();
    try collector.add(.{ .start = 0, .len = 8 });
    try collector.add(.{ .start = 8, .len = 8 });
    var first = try Work.init(gpa);
    defer first.deinit();
    try std.testing.expect(try first.advance(&collector, null, &cancel, &waiting));
    try std.testing.expectEqual(@as(usize, 1), first.checked);
    try std.testing.expectEqual(@as(usize, 1), first.reused);
    try std.testing.expect(first.diagnostics.items.len > 0);
    try std.testing.expectEqual(@as(u32, 0), first.diagnostics.items[0].origin);
    var next = try Work.init(gpa);
    defer next.deinit();
    waiting.store(1, .release);
    try std.testing.expect(!try next.advance(&collector, first.cache, &cancel, &waiting));
    waiting.store(0, .release);
    try std.testing.expect(try next.advance(&collector, first.cache, &cancel, &waiting));
    try std.testing.expectEqual(@as(usize, 0), next.checked);
    try std.testing.expectEqual(@as(usize, 2), next.reused);
    try std.testing.expectEqualSlices(Located, first.diagnostics.items, next.diagnostics.items);
    // Equal-length content changes must miss, even though spans did not change.
    collector.source = "<B>x</B><B>x</B>";
    var changed = try Work.init(gpa);
    defer changed.deinit();
    try std.testing.expect(try changed.advance(&collector, next.cache, &cancel, &waiting));
    try std.testing.expectEqual(@as(usize, 1), changed.checked);
    try std.testing.expectEqual(@as(usize, 0), changed.diagnostics.items.len);
}

test "HTML checking is cancellable and allocation failures release entries" {
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: std.mem.Allocator) !void {
            var budget: Budget = .{};
            defer std.debug.assert(budget.live.load(.acquire) == 0);
            const cancel: std.atomic.Value(bool) = .init(false);
            const waiting: std.atomic.Value(usize) = .init(0);
            var collector: Collector = .{ .allocator = gpa, .source = "<B>x</I>" };
            defer collector.deinit();
            try collector.add(.{ .start = 0, .len = 8 });
            var work = try Work.init(gpa);
            work.budget = &budget;
            defer work.deinit();
            _ = try work.advance(&collector, null, &cancel, &waiting);
            var reused = try Work.init(gpa);
            reused.budget = &budget;
            defer reused.deinit();
            _ = try reused.advance(&collector, work.cache, &cancel, &waiting);
        }
    }.run, .{});
    const cancel: std.atomic.Value(bool) = .init(true);
    const waiting: std.atomic.Value(usize) = .init(0);
    var collector: Collector = .{ .allocator = std.testing.allocator, .source = "<B>x</I>" };
    defer collector.deinit();
    try collector.add(.{ .start = 0, .len = 8 });
    var work = try Work.init(std.testing.allocator);
    defer work.deinit();
    try std.testing.expectError(error.Cancelled, work.advance(&collector, null, &cancel, &waiting));
}

pub fn message(gpa: std.mem.Allocator, source: []const u8, item: Located) ![]u8 {
    const d = item.diagnostic;
    if (d.code == .mismatched_tag) if (d.related) |related| {
        return std.fmt.allocPrint(gpa, "HTML label: closing tag '</{s}>' does not match '<{s}>'.\n{s}", .{ shortName(source, item.origin, d.span), shortName(source, item.origin, related), d.code.info().hint });
    };
    return std.fmt.allocPrint(gpa, "HTML label: {s}\n{s}", .{ d.code.info().summary, d.code.info().hint });
}
fn shortName(source: []const u8, origin: u32, span: dot.Span) []const u8 {
    const start = @as(usize, origin) + span.start;
    var len = @min(@as(usize, span.len), 80);
    while (len > 0 and !std.unicode.utf8ValidateSlice(source[start..][0..len])) len -= 1;
    return source[start..][0..len];
}

test "retained HTML budget covers shared generations and releases on final owner" {
    const gpa = std.testing.allocator;
    var budget: Budget = .{};
    const cancel: std.atomic.Value(bool) = .init(false);
    const waiting: std.atomic.Value(usize) = .init(0);
    var collector: Collector = .{ .allocator = gpa, .source = "<B>x</B>" };
    defer collector.deinit();
    try collector.add(.{ .start = 0, .len = 8 });
    var first = try Work.init(gpa);
    first.budget = &budget;
    _ = try first.advance(&collector, null, &cancel, &waiting);
    const bytes = budget.live.load(.acquire);
    try std.testing.expect(bytes > 0);
    var second = try Work.init(gpa);
    second.budget = &budget;
    _ = try second.advance(&collector, first.cache, &cancel, &waiting);
    try std.testing.expectEqual(bytes, budget.live.load(.acquire));
    first.deinit();
    try std.testing.expectEqual(bytes, budget.live.load(.acquire));
    second.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.live.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), budget.entries.load(.acquire));
    budget.live.store(Budget.limit, .release);
    var capped = try Work.init(gpa);
    capped.budget = &budget;
    defer capped.deinit();
    try std.testing.expect(try capped.advance(&collector, null, &cancel, &waiting));
    try std.testing.expectEqual(@as(u32, 0), capped.cache.?.entries.count());
    try std.testing.expect(!capped.incomplete); // Cache pressure must not skip checking.
}

test "compact label spans preserve varint boundaries and reject partial records" {
    var spans: Spans = .{};
    defer spans.deinit(std.testing.allocator);
    const expected = [_]dot.Span{
        .{ .start = 0, .len = 0 },
        .{ .start = 127, .len = 128 },
        .{ .start = 16384, .len = 16383 },
        .{ .start = 1 << 21, .len = 1 << 21 },
        .{ .start = std.math.maxInt(u32), .len = 0 },
    };
    for (expected) |span| try spans.append(std.testing.allocator, span, 64);
    var it: Spans.Iterator = .{};
    for (expected) |span| try std.testing.expectEqual(span, it.next(&spans).?);
    try std.testing.expect(it.next(&spans) == null);
    const bytes = spans.encoded.items.len;
    try std.testing.expectError(error.LabelSpanOverflow, spans.append(std.testing.allocator, .{ .start = std.math.maxInt(u32), .len = 1 }, 64));
    try std.testing.expectError(error.UnorderedLabelSpan, spans.append(std.testing.allocator, .{ .start = 0, .len = 1 }, 64));
    try std.testing.expectError(error.LabelSpanBudget, spans.append(std.testing.allocator, .{ .start = std.math.maxInt(u32), .len = 0 }, bytes + 1));
    try std.testing.expectEqual(expected.len, spans.count);
    try std.testing.expectEqual(bytes, spans.encoded.items.len);
}

test "compact selection checks more than 65536 labels within source-derived storage" {
    const gpa = std.testing.allocator;
    const record = "label=<>";
    const count = 70000;
    const source = try gpa.alloc(u8, record.len * count);
    defer gpa.free(source);
    var collector: Collector = .{ .allocator = gpa, .source = source };
    defer collector.deinit();
    for (0..count) |i| {
        const at: u32 = @intCast(i * record.len);
        @memcpy(source[at..][0..record.len], record);
        Collector.emit(&collector, .{ .start = at, .len = 5 }, .{ .start = at + 6, .len = 2 });
    }
    try std.testing.expect(!collector.incomplete);
    try std.testing.expectEqual(@as(usize, count), collector.spans.count);
    try std.testing.expectEqual(@as(usize, count * 2), collector.spans.encoded.items.len);
    try std.testing.expect(collector.spans.encoded.capacity <= source.len / 4 + 16);
    var work = try Work.init(gpa);
    defer work.deinit();
    const cancel: std.atomic.Value(bool) = .init(false);
    const waiting: std.atomic.Value(usize) = .init(0);
    try std.testing.expect(try work.advance(&collector, null, &cancel, &waiting));
    try std.testing.expectEqual(@as(usize, count), work.cursor);
    try std.testing.expect(!work.incomplete);
    try std.testing.expectEqual(@as(usize, 1), work.checked);
    try std.testing.expectEqual(@as(usize, count - 1), work.reused);
}

test "compact label span growth releases allocations on failure" {
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: std.mem.Allocator) !void {
            var spans: Spans = .{};
            defer spans.deinit(gpa);
            for (0..1000) |i| try spans.append(gpa, .{ .start = @intCast(i * 128), .len = 4 }, 4096);
            var it: Spans.Iterator = .{};
            for (0..1000) |i| try std.testing.expectEqual(dot.Span{ .start = @intCast(i * 128), .len = 4 }, it.next(&spans).?);
        }
    }.run, .{});
}
