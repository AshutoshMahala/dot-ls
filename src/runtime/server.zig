//! Owns document state, jobs, accounting and synchronization. No protocol imports.
//! Dispatch/query operations require the caller's transaction lock. Worker
//! publication, freshness checks and stop acquire their own state lock.
const std = @import("std");
const pos = @import("../text/types.zig");
const labels = @import("../features/labels.zig");
const actions = @import("../features/code_actions.zig");
const Document = @import("document.zig").Document;
const jobs = @import("job.zig");
const Job = jobs.Job;
const requests = @import("requests.zig");
const limits = @import("limits.zig");
const pipeline = @import("../analysis/pipeline.zig");
const references = @import("../features/references.zig");
const outline = @import("../features/outline.zig");
const snapshot = @import("snapshot.zig");
const worker = @import("worker.zig");
pub const Finding = @import("../analysis/diagnostic_text.zig").Finding;
pub const Notice = struct { uri: []const u8, version: i64, generation: u64, items: []const Finding };
pub const Positioned = struct { index: *snapshot.Completion, point: pos.Position };
pub const View = union(enum) {
    completion: Positioned,
    hover: Positioned,
    references: struct { index: *snapshot.References, point: pos.Position, include: bool },
    outline: *snapshot.Outline,
    fixes: struct { index: *snapshot.Fixes, range: pos.Range },
    /// Reader ownership changes require the state lock.
    pub fn retain(self: View) void {
        switch (self) {
            .completion, .hover => |v| _ = v.index.retain(),
            .references => |v| _ = v.index.retain(),
            .outline => |v| _ = v.retain(),
            .fixes => |v| _ = v.index.retain(),
        }
    }
    pub fn release(self: View, allocator: std.mem.Allocator) void {
        switch (self) {
            .completion, .hover => |v| v.index.release(allocator),
            .references => |v| v.index.release(allocator),
            .outline => |v| v.release(allocator),
            .fixes => |v| v.index.release(allocator),
        }
    }
};
/// Borrowed synchronous callbacks. Called under the state lock; retain a feature
/// reader/copy request metadata here, then encode after the operation returns.
pub const Events = struct {
    context: *anyopaque,
    failure: requests.Observer,
    reply: *const fn (*anyopaque, requests.Id, View) anyerror!void,
    diagnostics: *const fn (*anyopaque, Notice) anyerror!void,
    analysis_failed: *const fn (*anyopaque, []const u8, i64, u64) anyerror!void,
    fn respond(self: Events, id: requests.Id, view: View) !void {
        try self.reply(self.context, id, view);
    }
};
const Starter = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque) anyerror!std.Thread,
};
pub const Update = enum { ignored, limited, copied, transferred };
pub const Server = struct {
    html_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    documents: std.ArrayList(Document) = .empty,
    active: ?*Job = null,
    source_bytes: usize = 0,
    index_bytes: usize = 0,
    context_bytes: usize = 0,
    outline_bytes: usize = 0,
    html_cache_bytes: usize = 0,
    fix_bytes: usize = 0,
    html_budget: labels.Budget = .{},
    // Queued syntax jobs plus any large packet being read/decoded by the dispatcher.
    syntax_pending: std.atomic.Value(usize) = .init(0),
    generation: u64 = 0,
    stopping: bool = false,
    encoding: pos.Encoding = .utf16,
    related_information: bool = false,
    worker: ?std.Thread = null,
    pub fn releaseIntake(self: *Server, priority: *bool) void {
        if (!priority.*) return;
        priority.* = false;
        _ = self.syntax_pending.fetchSub(1, .release);
        self.mutex.lockUncancelable(self.io);
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }
    pub fn find(self: *Server, uri: []const u8) ?usize {
        for (self.documents.items, 0..) |doc, i| if (std.mem.eql(u8, doc.uri, uri)) return i;
        return null;
    }
    pub fn invalidate(self: *Server, doc: *Document, observer: requests.Observer) void {
        if (doc.outline_index) |index| {
            index.release(self.allocator);
            doc.outline_index = null;
        }
        doc.outline_done = false;
        if (doc.fixes) |old| old.release(self.allocator);
        doc.fixes = null;
        doc.fixes_done = false;
        self.failRequests(doc, .modified, observer) catch {};
        if (doc.index_pending) |job| {
            self.source_bytes -= job.allocation.len;
            job.destroy(self.allocator);
            doc.index_pending = null;
        }
        if (doc.completion) |index| {
            index.release(self.allocator);
            doc.completion = null;
        }
        doc.completion_done = false;
        if (doc.references) |index| {
            index.release(self.allocator);
            doc.references = null;
        }
        if (doc.pending) |job| {
            _ = self.syntax_pending.fetchSub(1, .release);
            self.source_bytes -= job.allocation.len;
            job.destroy(self.allocator);
            doc.pending = null;
        }
        if (self.active) |job| if (std.mem.eql(u8, job.uri, doc.uri)) {
            job.cancel.store(true, .release);
        };
        self.generation += 1;
        doc.generation = self.generation;
    }
    pub fn beginIntake(self: *Server, length: usize, priority: *bool) void {
        if (length >= limits.intake_priority) {
            _ = self.syntax_pending.fetchAdd(1, .release);
            priority.* = true;
        }
    }
    pub fn setFixes(self: *Server, doc: *Document, offers: []const actions.Fix, failed: bool) void {
        doc.setFixes(self.allocator, offers, failed, &self.fix_bytes);
    }
    pub fn dropHtmlCache(self: *Server, doc: *Document) void {
        if (doc.html_cache) |cache| self.html_cache_bytes -= cache.payload_bytes;
        _ = doc.dropHtmlCache(self.allocator);
    }
    pub fn failRequests(self: *Server, doc: *Document, reason: requests.Failure, observer: requests.Observer) !void {
        defer doc.requests.clear(self.allocator);
        for (doc.requests.items()) |request| try observer.fail(request.id, reason);
    }
    pub fn cancelRequest(self: *Server, id: requests.Id, observer: requests.Observer) !bool {
        for (self.documents.items) |*doc| {
            for (doc.requests.items(), 0..) |request, i| {
                if (request.id.matchesCancellation(id)) {
                    const removed = doc.requests.orderedRemove(i);
                    defer removed.id.deinit(self.allocator);
                    try observer.fail(removed.id, .cancelled);
                    return true;
                }
            }
        }
        return false;
    }
    pub fn update(self: *Server, uri: []const u8, input: jobs.Input, version: i64, opening: bool, callbacks: worker.Callbacks, observer: requests.Observer) !Update {
        const Spawn = struct {
            state: *Server,
            callbacks: worker.Callbacks,
            fn start(ctx: *anyopaque) !std.Thread {
                const spawn_context: *@This() = @ptrCast(@alignCast(ctx));
                return worker.start(spawn_context.state, spawn_context.callbacks);
            }
        };
        var spawn: Spawn = .{ .state = self, .callbacks = callbacks };
        return self.updateWithStarter(uri, input, version, opening, .{ .context = &spawn, .start = Spawn.start }, observer);
    }
    fn updateWithStarter(self: *Server, uri: []const u8, input: jobs.Input, version: i64, opening: bool, starter: Starter, observer: requests.Observer) !Update {
        if (uri.len > limits.uri) return .ignored;
        var index = self.find(uri);
        if (index == null) {
            if (!opening or self.documents.items.len == limits.documents) return .ignored;
            const key = try self.allocator.dupe(u8, uri);
            errdefer self.allocator.free(key);
            try self.documents.append(self.allocator, .{ .uri = key, .version = version, .generation = 0 });
            index = self.documents.items.len - 1;
        }
        const doc = &self.documents.items[index.?];
        self.invalidate(doc, observer);
        doc.version = version;
        const retained = if (input.packet) |packet| packet.len else input.text.len;
        if (!limits.admitsSource(input.text.len, retained, self.source_bytes)) return .limited;
        var prepared = try jobs.Prepared.init(self.allocator, input, uri, version, doc.generation);
        defer prepared.deinit(self.allocator);
        if (self.worker == null) self.worker = try starter.start(starter.context);
        const job = prepared.commit();
        if (doc.html_cache) |cache| {
            cache.retain();
            job.previous_html = cache;
        }
        doc.pending = job;
        _ = self.syntax_pending.fetchAdd(1, .release);
        self.source_bytes += retained;
        self.condition.signal(self.io);
        return if (input.packet != null) .transferred else .copied;
    }
    /// Transfers the retired document's final URI ownership to the caller, so it
    /// can remain alive until the synchronous close notification has been sent.
    pub fn close(self: *Server, uri: []const u8, observer: requests.Observer) ?Document {
        const i = self.find(uri) orelse return null;
        self.invalidate(&self.documents.items[i], observer);
        self.dropHtmlCache(&self.documents.items[i]);
        return self.documents.orderedRemove(i);
    }
    pub fn stop(self: *Server, observer: requests.Observer) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        for (self.documents.items) |*doc| self.invalidate(doc, observer);
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.worker) |thread| thread.join();
        for (self.documents.items) |*doc| {
            self.dropHtmlCache(doc);
            doc.deinit(self.allocator);
        }
        self.documents.deinit(self.allocator);
    }
    pub fn hasDocument(self: *Server, uri: []const u8) bool {
        return self.find(uri) != null;
    }
    pub fn configure(self: *Server, encoding: pos.Encoding, related: bool) void {
        self.encoding = encoding;
        self.related_information = related;
    }
    pub fn retireAll(self: *Server, observer: requests.Observer) void {
        for (self.documents.items) |*doc| self.invalidate(doc, observer);
    }
    pub fn current(self: *Server, uri: []const u8, generation: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = self.find(uri) orelse return false;
        return !self.stopping and self.documents.items[i].generation == generation;
    }
    fn publish(self: *Server, events: Events, comptime operation: anytype, args: anytype) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return @call(.auto, operation, .{ self, events } ++ args);
    }
    pub fn advance(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        return switch (job.phase) {
            .syntax => self.analyze(job, encoding, events),
            .html => self.buildHtml(job, encoding, events),
            .context => self.buildContext(job, encoding, events),
            .index => self.buildIndex(job, encoding, events),
        };
    }
    pub fn failedJob(self: *Server, job: *Job, events: Events) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = self.find(job.uri) orelse return;
        if (self.stopping or self.documents.items[i].generation != job.generation) return;
        if (job.phase == .syntax) try events.analysis_failed(events.context, job.uri, job.version, job.generation);
        try self.failRequests(&self.documents.items[i], .reference_failed, events.failure);
    }
    pub fn reportRequests(self: *Server, queue: *requests.Queue, reason: requests.Failure, observer: requests.Observer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (queue.items()) |request| try observer.fail(request.id, reason);
    }
    fn pending(self: *Server, doc: Document) bool {
        return doc.pending != null or doc.index_pending != null or if (self.active) |job| std.mem.eql(u8, job.uri, doc.uri) and job.generation == doc.generation else false;
    }
    /// Caller holds the state lock through the synchronous reply callback.
    pub fn queryFeature(self: *Server, uri: ?[]const u8, query: requests.Request, events: Events) !void {
        const i = if (uri) |u| self.find(u) else null;
        if (i == null) return events.failure.fail(query.id, switch (query.kind) {
            .symbols => .outline_document,
            .references => .references_document,
            .completion, .hover => .completion_document,
        });
        const doc = &self.documents.items[i.?];
        switch (query.kind) {
            .symbols => if (doc.outline_done) {
                if (doc.outline_index) |index| return events.respond(query.id, .{ .outline = index });
                return events.failure.fail(query.id, .outline_unavailable);
            },
            .references => if (doc.references) |index| {
                return events.respond(query.id, .{ .references = .{ .index = index, .point = query.point, .include = query.include } });
            },
            .completion, .hover => if (doc.completion) |index| {
                return events.respond(query.id, if (query.kind == .hover) .{ .hover = .{ .index = index, .point = query.point } } else .{ .completion = .{ .index = index, .point = query.point } });
            } else if (doc.completion_done) return events.failure.fail(query.id, .completion_unavailable),
        }
        if (!self.pending(doc.*)) return events.failure.fail(query.id, switch (query.kind) {
            .symbols => .outline_incomplete,
            .references => .references_incomplete,
            .completion, .hover => .completion_unavailable,
        });
        if (!doc.requests.canAppend(query.id)) return events.failure.fail(query.id, switch (query.kind) {
            .symbols => .outline_limit,
            .references => .references_limit,
            .completion, .hover => .pending_limit,
        });
        try doc.requests.append(self.allocator, query);
    }
    pub fn requestFixes(self: *Server, uri: []const u8, id: requests.Id, range: pos.Range, generation: ?i64, mixed: bool, events: Events) !void {
        const i = self.find(uri) orelse return events.failure.fail(id, .actions_document);
        const doc = &self.documents.items[i];
        const offers = doc.fixes orelse return events.failure.fail(id, if (doc.fixes_done) .fixes_unavailable else .diagnostics_not_ready);
        if (mixed or if (generation) |g| g < 0 or @as(u64, @intCast(g)) != doc.generation else false) return events.failure.fail(id, .stale_diagnostics);
        try events.respond(id, .{ .fixes = .{ .index = offers, .range = range } });
    }

    fn environment(self: *Server) pipeline.Environment {
        return .{ .allocator = self.allocator, .html_allocator = self.html_allocator, .syntax_pending = &self.syntax_pending, .html_budget = &self.html_budget, .related_information = self.related_information, .finding_limit = limits.findings };
    }
    fn buildContext(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        var built = pipeline.buildContext(self.environment(), job, encoding) catch |err| {
            if (err == error.Yield) return true;
            if (err == error.Cancelled) return false;
            return err;
        };
        defer built.deinit(self.allocator);
        return self.publish(events, publishContext, .{ job, &built });
    }
    fn publishContext(self: *Server, events: Events, job: *Job, built: *pipeline.Context) !bool {
        const i = self.find(job.uri) orelse return false;
        const doc = &self.documents.items[i];
        if (self.stopping or doc.generation != job.generation or job.cancel.load(.acquire)) return false;
        doc.outline_done = true;
        if (built.symbols) |owned| {
            doc.outline_index = snapshot.Outline.create(self.allocator, owned, doc.uri, doc.version, doc.generation, owned.bytes(), &self.outline_bytes, outline.global_bytes) catch null;
            if (doc.outline_index != null) built.symbols = null;
        }
        var symbol_n: usize = 0;
        while (symbol_n < doc.requests.items().len) {
            if (doc.requests.items()[symbol_n].kind != .symbols) {
                symbol_n += 1;
                continue;
            }
            const request = doc.requests.orderedRemove(symbol_n);
            defer request.id.deinit(self.allocator);
            if (doc.outline_index) |index| try events.respond(request.id, .{ .outline = index }) else try events.failure.fail(request.id, .outline_unavailable);
        }
        doc.completion_done = true;
        if (built.index) |owned| {
            doc.completion = snapshot.Completion.create(self.allocator, owned, doc.uri, doc.version, doc.generation, owned.bytes(), &self.context_bytes, limits.completion_total) catch null;
            if (doc.completion != null) built.index = null;
        }
        var n: usize = 0;
        while (n < doc.requests.items().len) {
            if (doc.requests.items()[n].kind != .completion and doc.requests.items()[n].kind != .hover) {
                n += 1;
                continue;
            }
            const request = doc.requests.orderedRemove(n);
            defer request.id.deinit(self.allocator);
            if (doc.completion) |ready| {
                try events.respond(request.id, if (request.kind == .hover) .{ .hover = .{ .index = ready, .point = request.point } } else .{ .completion = .{ .index = ready, .point = request.point } });
            } else try events.failure.fail(request.id, .completion_exceeded);
        }
        return pipeline.afterContext(job);
    }
    fn buildHtml(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        return self.analyzeHtml(job, encoding, events) catch |err| {
            if (err == error.Yield) return true;
            return err;
        };
    }
    fn analyzeHtml(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        const ready = pipeline.advanceHtml(self.environment(), job) catch |err| {
            if (err == error.Cancelled) return false;
            return err;
        };
        return if (ready) self.finishHtml(job, encoding, events) else true;
    }

    fn finishHtml(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        job.phase_result = pipeline.finishHtml(self.environment(), job, encoding) catch |err| {
            if (err == error.Cancelled) return false;
            return err;
        };
        return self.publish(events, publishHtml, .{ job, &job.phase_result.? });
    }
    /// The application calls this after encoding borrowed phase notices.
    pub fn releaseResult(self: *Server, job: *Job) void {
        job.releaseResult(self.allocator);
    }
    fn publishHtml(self: *Server, events: Events, job: *Job, built: *pipeline.Html) !bool {
        const i = self.find(job.uri) orelse return false;
        const doc = &self.documents.items[i];
        if (self.stopping or doc.generation != job.generation or job.cancel.load(.acquire)) return false;
        self.setFixes(doc, built.offers.items, built.fixes_failed);
        try events.diagnostics(events.context, .{ .uri = job.uri, .version = job.version, .generation = job.generation, .items = built.diagnostics.items });
        const old_bytes = if (doc.html_cache) |cache| cache.payload_bytes else 0;
        if (job.html.?.cache) |cache| if (cache.payload_bytes <= limits.html_cache_total - (self.html_cache_bytes - old_bytes)) {
            self.dropHtmlCache(doc);
            doc.html_cache = job.html.?.cache;
            self.html_cache_bytes += job.html.?.cache.?.payload_bytes;
            job.html.?.cache = null;
        };
        pipeline.afterHtml(self.allocator, job);
        return true;
    }
    fn buildIndex(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        var index: ?references.Index = pipeline.buildReferences(self.environment(), job, encoding) catch |err| {
            if (err == error.Yield) return true;
            return false;
        };
        defer if (index) |*owned| owned.deinit(self.allocator);
        return self.publish(events, publishReferences, .{ job, &index });
    }
    fn publishReferences(self: *Server, events: Events, job: *Job, index: *?references.Index) !bool {
        const i = self.find(job.uri) orelse return false;
        const doc = &self.documents.items[i];
        if (self.stopping or doc.generation != job.generation or job.cancel.load(.acquire)) return false;
        const owned = index.*.?;
        doc.references = snapshot.References.create(self.allocator, owned, doc.uri, doc.version, doc.generation, owned.bytes(), &self.index_bytes, limits.references_total) catch return false;
        index.* = null;
        defer doc.requests.clear(self.allocator);
        for (doc.requests.items()) |request| try events.respond(request.id, .{ .references = .{ .index = doc.references.?, .point = request.point, .include = request.include } });
        return false;
    }

    fn analyze(self: *Server, job: *Job, encoding: pos.Encoding, events: Events) !bool {
        if (!try pipeline.syntax(self.environment(), job, encoding)) return false;
        return self.publish(events, publishSyntax, .{job});
    }
    fn publishSyntax(self: *Server, events: Events, job: *Job) !bool {
        const i = self.find(job.uri) orelse return false;
        if (self.stopping or self.documents.items[i].generation != job.generation) return false;
        self.setFixes(&self.documents.items[i], job.fixes.items, job.fixes_failed);
        try events.diagnostics(events.context, .{ .uri = job.uri, .version = job.version, .generation = job.generation, .items = job.diagnostics.items });
        if (job.labels.?.spans.count == 0 and !job.labels.?.incomplete) self.dropHtmlCache(&self.documents.items[i]);
        pipeline.afterSyntax(self.allocator, job);
        return true;
    }
};

const Recorder = struct {
    calls: usize = 0,
    reason: ?requests.Failure = null,
    fail_output: bool = false,
    fn observe(ctx: *anyopaque, _: requests.Id, reason: requests.Failure) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.reason = reason;
        if (self.fail_output) return error.TestOutputFailure;
    }
    fn observer(self: *Recorder) requests.Observer {
        return .{ .context = self, .failure = observe };
    }
    fn failStart(_: *anyopaque) !std.Thread {
        return error.TestWorkerFailure;
    }
};

test "invalidation releases queued jobs and requests but only cancels the active job" {
    const allocator = std.testing.allocator;
    var state: Server = .{ .allocator = allocator, .html_allocator = allocator, .io = std.testing.io };
    var recorder: Recorder = .{ .fail_output = true };
    defer state.stop(recorder.observer());
    try state.documents.append(allocator, .{ .uri = try allocator.dupe(u8, "untitled:test"), .version = 1, .generation = 0 });
    const doc = &state.documents.items[0];
    try doc.requests.append(allocator, .{ .id = .{ .string = "owned" }, .point = .{ .line = 0, .character = 0 } });
    var first = try jobs.Prepared.init(allocator, .{ .text = "graph {}" }, doc.uri, 1, 0);
    defer first.deinit(allocator);
    var second = try jobs.Prepared.init(allocator, .{ .text = "graph {a}" }, doc.uri, 1, 0);
    defer second.deinit(allocator);
    var active = try jobs.Prepared.init(allocator, .{ .text = "graph {b}" }, doc.uri, 1, 0);
    defer active.deinit(allocator);
    doc.pending = first.commit();
    doc.index_pending = second.commit();
    const running = active.commit();
    state.active = running;
    state.source_bytes = doc.pending.?.allocation.len + doc.index_pending.?.allocation.len + running.allocation.len;
    state.syntax_pending.store(1, .release);
    state.invalidate(doc, recorder.observer());
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(requests.Failure.modified, recorder.reason.?);
    try std.testing.expectEqual(@as(usize, 0), doc.requests.items().len);
    try std.testing.expect(doc.pending == null and doc.index_pending == null);
    try std.testing.expectEqual(@as(usize, 0), state.syntax_pending.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), doc.generation);
    try std.testing.expect(running.cancel.load(.acquire));
    try std.testing.expectEqual(running.allocation.len, state.source_bytes);
    state.active = null;
    state.source_bytes -= running.allocation.len;
    running.destroy(allocator);
}

test "failed worker startup and preparation never transfer the caller packet" {
    // Refuse in-place resizes so that every run makes the same allocations.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(allocator: std.mem.Allocator) !void {
            var recorder: Recorder = .{};
            var state: Server = .{ .allocator = allocator, .html_allocator = allocator, .io = std.testing.io };
            defer state.stop(recorder.observer());
            const packet = try std.testing.allocator.dupe(u8, "--graph {}--");
            defer std.testing.allocator.free(packet);
            const result = state.updateWithStarter("untitled:failure", .{ .text = packet[2..10], .packet = packet }, 1, true, .{ .context = &recorder, .start = Recorder.failStart }, recorder.observer()) catch |err| {
                if (err != error.TestWorkerFailure) return err;
                try std.testing.expectEqualStrings("--graph {}--", packet);
                try std.testing.expectEqual(@as(usize, 0), state.source_bytes);
                try std.testing.expect(state.documents.items[0].pending == null and state.worker == null);
                return;
            };
            _ = result;
            return error.TestExpectedWorkerFailure;
        }
    }.run, .{});
}

test "cancellation frees removed IDs and source admission leaves the caller packet" {
    const allocator = std.testing.allocator;
    var recorder: Recorder = .{};
    var state: Server = .{ .allocator = allocator, .html_allocator = allocator, .io = std.testing.io };
    defer state.stop(recorder.observer());
    try state.documents.append(allocator, .{ .uri = try allocator.dupe(u8, "untitled:test"), .version = 1, .generation = 0 });
    try state.documents.items[0].requests.append(allocator, .{ .id = .{ .string = "cancel" }, .point = .{ .line = 0, .character = 0 } });
    try std.testing.expect(try state.cancelRequest(.{ .string = "cancel" }, recorder.observer()));
    try std.testing.expectEqual(requests.Failure.cancelled, recorder.reason.?);
    try std.testing.expectEqual(@as(usize, 0), state.documents.items[0].requests.items().len);
    const packet = try allocator.dupe(u8, "graph {}");
    defer allocator.free(packet);
    state.source_bytes = limits.sources;
    const result = try state.updateWithStarter("untitled:test", .{ .text = packet, .packet = packet }, 2, true, .{ .context = &recorder, .start = Recorder.failStart }, recorder.observer());
    state.source_bytes = 0;
    try std.testing.expectEqual(Update.limited, result);
    try std.testing.expectEqualStrings("graph {}", packet);
    try std.testing.expect(state.documents.items[0].pending == null);
    try std.testing.expectEqual(@as(i64, 2), state.documents.items[0].version);
}

test "HTML publication keeps its owned findings alive through the encoder handoff" {
    const a = std.testing.allocator;
    var state: Server = .{ .allocator = a, .html_allocator = a, .io = std.testing.io };
    var failures: Recorder = .{};
    defer state.stop(failures.observer());
    try state.documents.append(a, .{ .uri = try a.dupe(u8, "uri"), .version = 1, .generation = 1 });
    var prepared = try jobs.Prepared.init(a, .{ .text = "digraph { a [label=<<B>x</I>>]; }" }, "uri", 1, 1);
    defer prepared.deinit(a);
    const job = prepared.commit();
    defer job.destroy(a);
    const Capture = struct {
        notice: ?Notice = null,
        fn receive(ctx: *anyopaque, value: Notice) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.notice = value;
        }
        fn unexpectedReply(_: *anyopaque, _: requests.Id, _: View) !void {
            return error.UnexpectedReply;
        }
        fn unexpectedFailure(_: *anyopaque, _: []const u8, _: i64, _: u64) !void {
            return error.UnexpectedFailure;
        }
    };
    var capture: Capture = .{};
    const events: Events = .{ .context = &capture, .failure = failures.observer(), .reply = Capture.unexpectedReply, .diagnostics = Capture.receive, .analysis_failed = Capture.unexpectedFailure };
    try std.testing.expect(try state.advance(job, .utf16, events));
    while (job.phase == .html) try std.testing.expect(try state.advance(job, .utf16, events));
    // advance has returned. The application has not encoded the notice yet.
    try std.testing.expect(job.phase_result != null);
    try std.testing.expect(capture.notice.?.items.len > 0);
    try std.testing.expect(capture.notice.?.items[0].message.len > 0);
    state.releaseResult(job);
    try std.testing.expect(job.phase_result == null);
}
