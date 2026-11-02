//! Analysis phases. Generic job views expose owned construction state, immutable
//! source/URI/generation and cancellation. This module never accesses documents,
//! runtime locks or protocol output. The runtime job owns and destroys the state.
const std = @import("std");
const pos = @import("../text/positions.zig");
const diagnostic_text = @import("diagnostic_text.zig");
const context = @import("../features/completion_context.zig");
const references = @import("../features/references.zig");
const labels = @import("../features/labels.zig");
const analysis = @import("dot.zig");
const outline = @import("../features/outline.zig");
const actions = @import("../features/code_actions.zig");
const Range = @import("../text/types.zig").Range;
const RelatedInformation = diagnostic_text.Related;
const Diagnostic = diagnostic_text.Finding;
pub const Environment = struct {
    allocator: std.mem.Allocator,
    html_allocator: std.mem.Allocator,
    syntax_pending: *std.atomic.Value(usize),
    html_budget: *labels.Budget,
    related_information: bool,
    finding_limit: usize,
};
pub const Context = struct {
    index: ?context.Index,
    symbols: ?outline.Index,
    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        if (self.index) |*v| v.deinit(allocator);
        if (self.symbols) |*v| v.deinit(allocator);
    }
};
pub const Html = struct {
    wording: std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(Diagnostic),
    offers: std.ArrayList(actions.Fix),
    fixes_failed: bool,
    pub fn deinit(self: *Html, allocator: std.mem.Allocator) void {
        self.wording.deinit();
        self.diagnostics.deinit(allocator);
        self.offers.deinit(allocator);
    }
};
pub fn buildContext(env: Environment, job: anytype, encoding: pos.Encoding) !Context {
    var index: ?context.Index = context.build(env.allocator, job.text, encoding, &job.cancel, env.syntax_pending) catch |err| blk: {
        if (err == error.Yield) return err;
        if (err == error.Cancelled) return err;
        break :blk null;
    };
    errdefer if (index) |*owned| owned.deinit(env.allocator);
    var symbols: ?outline.Index = null;
    errdefer if (symbols) |*owned| owned.deinit(env.allocator);
    if (index) |coordinates| if (job.outline_builder) |*builder| {
        symbols = builder.finish(coordinates.coordinates, &job.cancel, env.syntax_pending) catch |err| blk: {
            if (err == error.Yield) return err;
            if (err == error.Cancelled) return err;
            break :blk null;
        };
    };
    if (job.outline_builder) |*builder| builder.deinit();
    job.outline_builder = null;
    return .{ .index = index, .symbols = symbols };
}
pub fn syntax(env: Environment, job: anytype, encoding: pos.Encoding) !bool {
    var bag: analysis.Bag = .{};
    var scratch: analysis.Scratch = .{};
    job.builder = references.Builder.init(env.allocator, job.text, &job.cancel);
    const builder = &job.builder.?;
    job.labels = .{ .allocator = env.allocator, .source = job.text };
    job.outline_builder = .{ .allocator = env.allocator, .source = job.text };
    const result = analysis.runOutline(job.text, scratch.storage(), &bag, .{ .context = job, .is_requested = @TypeOf(job.*).poll }, builder, &job.labels.?, &job.outline_builder.?);
    // Only grammar/recovery results are useful. Resource and cancellation
    // failures must not present a truncated outline as complete.
    if (result.outcome != .success and result.outcome != .invalid_syntax) job.outline_builder.?.failed = true;
    if (result.outcome == .cancelled or job.cancel.load(.acquire)) return false;
    job.wording = std.heap.ArenaAllocator.init(env.allocator);
    const wording = &job.wording.?;
    const diagnostics = &job.diagnostics;
    if (bag.items().len > 0) {
        var index = try pos.Index.initCancellable(env.allocator, job.text, &job.cancel);
        defer index.deinit(env.allocator);
        for (bag.items()) |d| {
            if (job.cancel.load(.acquire)) return false;
            var message_buffer: [1536]u8 = undefined;
            const rendered = diagnostic_text.format(&message_buffer, d) catch d.code.info().summary;
            const owned_message = try wording.allocator().dupe(u8, rendered);
            var note_storage: [2]diagnostic_text.Note = undefined;
            const notes = if (env.related_information) diagnostic_text.notes(d, &note_storage) else &.{};
            const related = try wording.allocator().alloc(RelatedInformation, notes.len);
            for (notes, related) |note, *out| {
                out.* = .{ .uri = job.uri, .range = .{
                    .start = try index.positionCancellable(job.text, note.span.start, encoding, &job.cancel),
                    .end = try index.positionCancellable(job.text, @as(usize, note.span.start) + note.span.len, encoding, &job.cancel),
                }, .message = note.message };
            }
            const range: Range = .{ .start = try index.positionCancellable(job.text, d.span.start, encoding, &job.cancel), .end = try index.positionCancellable(job.text, @as(usize, d.span.start) + d.span.len, encoding, &job.cancel) };
            var token: ?diagnostic_text.FixToken = null;
            if (!job.fixes_failed) if (d.fix) |fix| {
                const offer = try actions.Fix.capture(fix, range, d.span, job.text, 0, index, encoding, &job.cancel, null);
                job.fixes.append(env.allocator, offer) catch {
                    job.fixes_failed = true;
                };
                if (!job.fixes_failed) token = .{ .generation = job.generation, .index = job.fixes.items.len - 1 };
            };
            try diagnostics.append(env.allocator, .{
                .fix = token,
                .range = range,
                .severity = if (d.code.info().severity == .warning) .warning else .err,
                .code = d.code.structured(),
                .message = owned_message,
                .related = related,
            });
        }
    }
    if (bag.incomplete and result.completion == .complete) {
        const origin = pos.Position{ .line = 0, .character = 0 };
        try diagnostics.append(env.allocator, .{ .range = .{ .start = origin, .end = origin }, .severity = .information, .code = "dot-ls:validation-incomplete", .message = "DOT validation is incomplete. Further errors or repeated attributes may remain." });
    }
    if (result.completion != .complete) {
        const origin = pos.Position{ .line = 0, .character = 0 };
        try diagnostics.append(env.allocator, .{ .range = .{ .start = origin, .end = origin }, .severity = .information, .code = "dot-ls:incomplete", .message = "Syntax analysis is incomplete. Further errors may remain." });
    }
    if (job.cancel.load(.acquire)) return false;
    job.want_references = result.outcome == .success and result.completion == .complete and !builder.failed;
    return true;
}
pub fn finishHtml(env: Environment, job: anytype, encoding: pos.Encoding) !Html {
    const html_work = &job.html.?;
    var wording = std.heap.ArenaAllocator.init(env.allocator);
    errdefer wording.deinit();
    const arena = wording.allocator();
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(env.allocator);
    try diagnostics.appendSlice(env.allocator, job.diagnostics.items);
    var offers: std.ArrayList(actions.Fix) = .empty;
    errdefer offers.deinit(env.allocator);
    var fixes_failed = job.fixes_failed;
    if (!fixes_failed) offers.appendSlice(env.allocator, job.fixes.items) catch {
        fixes_failed = true;
    };
    var index: ?pos.Index = if (html_work.diagnostics.items.len > 0) try pos.Index.initBackground(env.allocator, job.text, &job.cancel, env.syntax_pending) else null;
    defer if (index) |*owned| owned.deinit(env.allocator);
    for (html_work.diagnostics.items) |item| {
        if (job.cancel.load(.acquire)) return error.Cancelled;
        if (env.syntax_pending.load(.acquire) != 0) return error.Yield;
        if (diagnostics.items.len >= env.finding_limit) {
            html_work.incomplete = true;
            break;
        }
        const d = item.diagnostic;
        const start = @as(usize, item.origin) + d.span.start;
        var related: []RelatedInformation = &.{};
        if (env.related_information) if (d.related) |span| {
            related = try arena.alloc(RelatedInformation, 1);
            const at = @as(usize, item.origin) + span.start;
            related[0] = .{ .uri = job.uri, .range = .{
                .start = try index.?.positionBackground(job.text, at, encoding, &job.cancel, env.syntax_pending),
                .end = try index.?.positionBackground(job.text, at + span.len, encoding, &job.cancel, env.syntax_pending),
            }, .message = "Related HTML construct starts here." };
        };
        const range: Range = .{ .start = try index.?.positionBackground(job.text, start, encoding, &job.cancel, env.syntax_pending), .end = try index.?.positionBackground(job.text, start + d.span.len, encoding, &job.cancel, env.syntax_pending) };
        var token: ?diagnostic_text.FixToken = null;
        if (!fixes_failed) if (d.suggestedFix()) |fix| {
            const offer = try actions.Fix.capture(fix, range, d.span, job.text, item.origin, index.?, encoding, &job.cancel, env.syntax_pending);
            offers.append(env.allocator, offer) catch {
                fixes_failed = true;
            };
            if (!fixes_failed) token = .{ .generation = job.generation, .index = offers.items.len - 1 };
        };
        try diagnostics.append(env.allocator, .{
            .fix = token,
            .range = range,
            .severity = if (d.code.info().severity == .warning) .warning else .err,
            .code = d.code.structured(),
            .related = related,
            .message = try labels.message(arena, job.text, item),
        });
    }
    if (html_work.incomplete) {
        const origin: pos.Position = .{ .line = 0, .character = 0 };
        try diagnostics.append(env.allocator, .{ .range = .{ .start = origin, .end = origin }, .severity = .information, .code = "dot-ls:html-incomplete", .message = "HTML label checking is incomplete. Further errors may remain." });
    }
    return .{ .wording = wording, .diagnostics = diagnostics, .offers = offers, .fixes_failed = fixes_failed };
}
pub fn advanceHtml(env: Environment, job: anytype) !bool {
    if (job.html_ready) return true;
    if (job.html == null) job.html = labels.Work.init(env.allocator) catch {
        job.html = .{ .allocator = env.allocator, .cache = null, .incomplete = true };
        job.html_ready = true;
        return true;
    };
    const html_work = &job.html.?;
    html_work.budget = env.html_budget;
    html_work.entry_allocator = env.html_allocator;
    const finished = html_work.advance(&job.labels.?, job.previous_html, &job.cancel, env.syntax_pending) catch |err| {
        if (err == error.Cancelled) return error.Cancelled;
        // Keep DOT findings and explicitly mark incomplete HTML checking.
        html_work.incomplete = true;
        job.html_ready = true;
        return true;
    };
    if (!finished) return false;
    job.html_ready = true;
    return true;
}
pub fn buildReferences(env: Environment, job: anytype, encoding: pos.Encoding) !references.Index {
    const builder = &job.builder.?;
    builder.waiting = env.syntax_pending;
    const index: ?references.Index = builder.finish(encoding) catch |err| {
        if (err == error.Yield) return err;
        return err;
    };
    // Release construction storage before replying to queued requests.
    builder.deinit();
    job.builder = null;
    return index.?;
}

/// Progress only after the application accepts the current phase result.
pub fn afterSyntax(allocator: std.mem.Allocator, job: anytype) void {
    if (job.labels.?.spans.count == 0 and !job.labels.?.incomplete) {
        job.fixes.deinit(allocator);
        job.fixes = .empty;
    }
    if (!job.want_references) {
        job.builder.?.deinit();
        job.builder = null;
    }
    job.phase = if (job.labels.?.spans.count > 0 or job.labels.?.incomplete) .html else .context;
}
pub fn afterHtml(allocator: std.mem.Allocator, job: anytype) void {
    job.fixes.deinit(allocator);
    job.fixes = .empty;
    job.phase = .context;
}
pub fn afterContext(job: anytype) bool {
    if (!job.want_references) return false;
    job.phase = .index;
    return true;
}
