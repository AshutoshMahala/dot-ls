const std = @import("std");
const build_options = @import("build_options");
const output = @import("protocol/output.zig");
const framing = @import("protocol/framing.zig");
const lsp = @import("protocol/lsp.zig");
const requests = @import("protocol/requests.zig");
const responses = @import("protocol/responses.zig");
pub const server_version = lsp.server_version;
const json_message = @import("protocol/json_message.zig");
const pos = @import("text/types.zig");
const worker = @import("runtime/worker.zig");
const runtime = @import("runtime/server.zig");
const State = runtime.Server;
const Job = @import("runtime/job.zig").Job;
const request_store = @import("runtime/requests.zig");
fn runtimeId(id: lsp.Id) request_store.Id {
    return switch (id) {
        .null => .null,
        .integer => |n| .{ .integer = n },
        .string => |v| .{ .string = v },
    };
}
fn wireId(id: request_store.Id) lsp.Id {
    return switch (id) {
        .null => .null,
        .integer => |n| .{ .integer = n },
        .string => |v| .{ .string = v },
    };
}
const Server = struct {
    state: State,
    output: *output.Queue,
    initialized: bool = false,
    versioned_edits: bool = false,
    hierarchical_symbols: bool = false,
    hover_markdown: bool = false,
    shutdown: bool = false,
    stopped: bool = false,

    fn failure(_: *Server, batch: *Batch, id: request_store.Id, code: i32, message: []const u8) !void {
        try batch.add(id, .{ .failure = .{ .code = code, .message = message } });
    }

    fn clear(_: *Server, batch: *Batch, uri: []const u8, version: ?i64, message: ?[]const u8) !void {
        try batch.add(.null, .{ .clear = .{ .uri = uri, .version = version, .message = message } });
    }

    fn update(self: *Server, batch: *Batch, uri: []const u8, text: []const u8, version: i64, opening: bool, message: *json_message.Message, packet: *?[]u8) !void {
        const result = try self.state.update(uri, .{ .text = text, .packet = if (message.inplace) packet.* else null }, version, opening, self.callbacks(), batch.observer());
        switch (result) {
            .transferred => packet.* = null,
            .limited => try self.clear(batch, uri, version, "Analysis skipped: source memory limit exceeded."),
            .copied, .ignored => {},
        }
    }

    fn callbacks(self: *Server) worker.Callbacks {
        return .{ .context = self, .advance = advance, .failed = phaseFailed, .failures = retiredRequests };
    }
    fn advance(ctx: *anyopaque, job: *Job, encoding: pos.Encoding) !bool {
        const self: *Server = @ptrCast(@alignCast(ctx));
        defer self.state.releaseResult(job);
        var batch: Batch = .{ .server = self, .role = .worker };
        defer batch.deinit();
        const result = self.state.advance(job, encoding, batch.events());
        try batch.flush();
        return result;
    }

    fn phaseFailed(ctx: *anyopaque, current: *Job) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        var batch: Batch = .{ .server = self, .role = .worker };
        defer batch.deinit();
        self.state.failedJob(current, batch.events()) catch {};
        batch.flush() catch {};
    }

    fn retiredRequests(ctx: *anyopaque, queue: *request_store.Queue, reason: request_store.Failure) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        var batch: Batch = .{ .server = self, .role = .worker };
        defer batch.deinit();
        self.state.reportRequests(queue, reason, batch.observer()) catch {};
        batch.flush() catch {};
    }

    fn codeActions(self: *Server, batch: *Batch, request: request_store.Id, decoded: ?requests.CodeActions) !void {
        const params = decoded orelse {
            try self.failure(batch, request, lsp.ErrorCode.invalid_params, "Code actions require an open document, valid range and diagnostics array.");
            return;
        };
        if (params.too_many) {
            try self.failure(batch, request, lsp.ErrorCode.invalid_params, "Code action diagnostic context exceeds its limit.");
            return;
        }
        if (!self.state.hasDocument(params.uri)) {
            try batch.observer().fail(request, .actions_document);
            return;
        }
        switch (params.only) {
            .invalid_array => {
                try self.failure(batch, request, lsp.ErrorCode.invalid_params, "Code action kinds must be an array.");
                return;
            },
            .invalid_strings => {
                try self.failure(batch, request, lsp.ErrorCode.invalid_params, "Code action kinds must be strings.");
                return;
            },
            .none => {
                try batch.add(request, .empty_result);
                return;
            },
            .all => {},
        }
        if (!self.versioned_edits) {
            try batch.add(request, .empty_result);
            return;
        }
        try self.state.requestFixes(params.uri, request, params.range, params.generation, params.mixed_generations, batch.events());
    }

    fn commit(self: *Server, batch: *Batch, comptime operation: anytype, args: anytype) !bool {
        self.state.mutex.lockUncancelable(self.state.io);
        const result = @call(.auto, operation, .{ self, batch } ++ args);
        self.state.mutex.unlock(self.state.io);
        try batch.flush();
        return result;
    }
    fn handle(self: *Server, message: *json_message.Message, packet: *?[]u8) !bool {
        var batch: Batch = .{ .server = self };
        defer batch.deinit();
        return self.commit(&batch, handleLocked, .{ message, packet });
    }
    fn handleLocked(self: *Server, batch: *Batch, message: *json_message.Message, packet: *?[]u8) !bool {
        const lifecycle: requests.Lifecycle = if (!self.initialized) .before_initialize else if (self.shutdown) .shutdown else .ready;
        const command = switch (requests.decode(message.value, lifecycle)) {
            .failure => |f| {
                try self.failure(batch, runtimeId(f.id), f.code, f.message);
                return false;
            },
            .command => |c| c,
        };
        const id: ?request_store.Id = if (command.id) |identifier| runtimeId(identifier) else null;
        const method = command.method;
        if (method == .exit) return true;
        if (!self.initialized) {
            if (method != .initialize) {
                if (id) |request| try self.failure(batch, request, lsp.ErrorCode.not_initialized, "Server not initialized");
                return false;
            }
            if (id == null) return false;
            const caps = command.body.initialize;
            self.versioned_edits = caps.versioned_edits;
            self.hierarchical_symbols = caps.hierarchical_symbols;
            self.hover_markdown = caps.hover_markdown;
            self.state.configure(caps.encoding, caps.related_information);
            self.initialized = true;
            try batch.add(id.?, .{ .initialized = caps.encoding });
            return false;
        }
        if (self.shutdown) {
            if (id) |request| try self.failure(batch, request, lsp.ErrorCode.invalid_request, "Server has shut down");
            return false;
        }
        if (method == .initialize) {
            if (id) |request| try self.failure(batch, request, lsp.ErrorCode.invalid_request, "Already initialized");
        } else if (method == .shutdown) {
            if (id) |request| {
                self.shutdown = true;
                self.state.retireAll(batch.observer());
                try batch.add(request, .null_result);
            }
        } else if (method == .code_actions) {
            try self.codeActions(batch, id orelse return false, command.body.code_actions);
        } else if (method == .symbols) {
            const request = id orelse return false;
            try self.state.queryFeature(command.body.symbols, .{ .id = request, .point = .{ .line = 0, .character = 0 }, .kind = .symbols }, batch.events());
        } else if (method == .references) {
            const request = id orelse return false;
            const params = command.body.references orelse {
                try self.failure(batch, request, lsp.ErrorCode.invalid_params, "References requires a document, position and includeDeclaration boolean.");
                return false;
            };
            try self.state.queryFeature(params.uri, .{ .id = request, .point = params.point, .include = params.include }, batch.events());
        } else if (method == .cancel) {
            const cancelled = command.body.cancel orelse return false;
            _ = try self.state.cancelRequest(runtimeId(cancelled), batch.observer());
        } else if (method == .completion or method == .hover) {
            const is_hover = method == .hover;
            const request_id = id orelse return false;
            const params = command.body.positioned orelse {
                try self.failure(batch, request_id, lsp.ErrorCode.invalid_params, "Completion requires an open document and a non-negative position.");
                return false;
            };
            try self.state.queryFeature(params.uri, .{ .id = request_id, .point = params.point, .kind = if (is_hover) .hover else .completion }, batch.events());
        } else if (method == .open or method == .change) {
            const params = command.body.update orelse return false;
            try self.update(batch, params.uri, params.text, params.version, params.opening, message, packet);
        } else if (method == .close) {
            const uri = command.body.close orelse return false;
            if (self.state.close(uri, batch.observer())) |closed| {
                var removed = closed;
                defer removed.deinit(self.state.allocator);
                try self.clear(batch, uri, null, null);
            }
        } else if (id) |request| try self.failure(batch, request, lsp.ErrorCode.method_not_found, "Method not found");
        return false;
    }
    fn deinit(self: *Server) void {
        if (self.stopped) return;
        self.stopped = true;
        var batch: Batch = .{ .server = self };
        defer batch.deinit();
        self.state.stop(batch.observer());
        batch.flush() catch {};
    }
};
// A transaction prepares response views under the state mutex. Leases keep
// arrays alive through encoding. The queue then owns independent frame chunks.
const Batch = struct {
    const Body = union(enum) {
        failure: struct { code: i32, message: []const u8 },
        clear: struct { uri: []const u8, version: ?i64, message: ?[]const u8, generation: ?u64 = null },
        diagnostics: runtime.Notice,
        initialized: pos.Encoding,
        empty_result,
        null_result,
        view: runtime.View,
    };
    const Reply = struct { id: request_store.Id, body: Body };
    server: *Server,
    replies: std.ArrayList(Reply) = .empty,
    role: output.Role = .dispatcher,
    /// Called under the state lock. The ID is copied; feature allocations are not.
    fn add(self: *Batch, id: request_store.Id, body: Body) !void {
        const a = self.server.state.allocator;
        const owned = try id.clone(a);
        errdefer owned.deinit(a);
        try self.replies.append(a, .{ .id = owned, .body = body });
        if (body == .view) body.view.retain();
    }
    fn events(self: *Batch) runtime.Events {
        return .{ .context = self, .failure = self.observer(), .reply = replyView, .diagnostics = notice, .analysis_failed = analysisFailed };
    }
    fn replyView(ctx: *anyopaque, id: request_store.Id, view: runtime.View) !void {
        const self: *Batch = @ptrCast(@alignCast(ctx));
        try self.add(id, .{ .view = view });
    }
    fn notice(ctx: *anyopaque, value: runtime.Notice) !void {
        const self: *Batch = @ptrCast(@alignCast(ctx));
        try self.add(.null, .{ .diagnostics = value });
    }
    fn analysisFailed(ctx: *anyopaque, uri: []const u8, version: i64, generation: u64) !void {
        const self: *Batch = @ptrCast(@alignCast(ctx));
        try self.add(.null, .{ .clear = .{ .uri = uri, .version = version, .message = "Analysis failed: resource or output failure.", .generation = generation } });
    }
    fn observer(self: *Batch) request_store.Observer {
        return .{ .context = self, .failure = observe };
    }
    fn observe(ctx: *anyopaque, id: request_store.Id, reason: request_store.Failure) !void {
        const self: *Batch = @ptrCast(@alignCast(ctx));
        const code: i32 = switch (reason) {
            .modified, .diagnostics_not_ready, .stale_diagnostics => lsp.ErrorCode.content_modified,
            .outline_document, .references_document, .completion_document, .actions_document => lsp.ErrorCode.invalid_params,
            .cancelled => lsp.ErrorCode.request_cancelled,
            else => lsp.ErrorCode.request_failed,
        };
        const message: []const u8 = switch (reason) {
            .modified => "Document changed before the request completed.",
            .cancelled => "Request cancelled.",
            .reference_failed => "Reference analysis failed.",
            .reference_unavailable => "Node references are unavailable: analysis did not complete within limits.",
            .outline_document => "Document outline requires an open document.",
            .references_document => "References requires an open document.",
            .completion_document => "Completion requires an open document and a non-negative position.",
            .actions_document => "Code actions require an open document.",
            .outline_unavailable => "Document outline exceeded analysis or index resource limits. Results were not truncated.",
            .outline_incomplete => "Document outline analysis did not complete within limits.",
            .references_incomplete => "Node references are unavailable: syntax analysis or index construction did not complete within limits.",
            .completion_unavailable => "Completion context is unavailable within resource limits.",
            .completion_exceeded => "Completion context exceeded resource limits.",
            .outline_limit => "Pending outline request limit exceeded.",
            .references_limit => "Pending reference request limit exceeded.",
            .pending_limit => "Pending request limit exceeded.",
            .fixes_unavailable => "Quick fixes are unavailable within resource limits.",
            .diagnostics_not_ready => "Current diagnostics are not ready. Request code actions again after diagnostics arrive.",
            .stale_diagnostics => "Document changed since these diagnostics were produced.",
        };
        try self.add(id, .{ .failure = .{ .code = code, .message = message } });
    }
    fn flush(self: *Batch) !void {
        for (self.replies.items) |reply| self.encode(reply) catch |err| {
            if (err == error.OutputBusy or err == error.FrameTooLarge) {
                responses.failure(self.server.state.allocator, .{ .queue = self.server.output, .control = true }, wireId(reply.id), lsp.ErrorCode.request_failed, "Response exceeded output capacity. Try again after pending replies arrive.") catch |failure| {
                    self.server.output.close();
                    return failure;
                };
            } else {
                self.server.output.close();
                return err;
            }
        };
    }
    fn encode(self: *Batch, reply: Reply) !void {
        const a = self.server.state.allocator;
        const w: responses.Destination = .{ .queue = self.server.output, .role = self.role };
        var control = w;
        control.control = true;
        const id = wireId(reply.id);
        switch (reply.body) {
            .failure => |v| try responses.failure(a, w, id, v.code, v.message),
            .clear => |v| {
                var gate: DiagnosticGate = .{ .server = self.server, .uri = v.uri, .generation = v.generation orelse 0 };
                var destination = control;
                if (v.generation) |generation| {
                    destination.tag = .{ .uri = v.uri, .generation = generation };
                    destination.gate = .{ .context = &gate, .current = DiagnosticGate.current };
                }
                try responses.clear(a, destination, v.uri, v.version, v.message);
            },
            .diagnostics => |v| {
                var gate: DiagnosticGate = .{ .server = self.server, .uri = v.uri, .generation = v.generation };
                try responses.diagnostics(a, .{ .queue = self.server.output, .role = self.role, .tag = .{ .uri = v.uri, .generation = v.generation }, .gate = .{ .context = &gate, .current = DiagnosticGate.current } }, v.uri, v.version, v.items);
            },
            .initialized => |v| try responses.initialized(a, control, id, v),
            .empty_result => try responses.result(a, w, id, @as([]const bool, &.{})),
            .null_result => try responses.result(a, control, id, @as(?u8, null)),
            .view => |view| switch (view) {
                .completion => |v| try responses.completion(a, w, id, v.index.value, v.point),
                .hover => |v| try responses.hover(a, w, id, v.index.value, v.point, self.server.hover_markdown),
                .references => |v| try responses.referencesReply(a, w, id, v.index.uri, v.index.value, v.point, v.include),
                .outline => |v| try responses.outlineReply(a, w, id, v.value, v.uri, self.server.hierarchical_symbols),
                .fixes => |v| try responses.codeActions(a, w, id, v.index.uri, v.index.version, v.index.value, v.range),
            },
        }
    }
    const DiagnosticGate = struct {
        server: *Server,
        uri: []const u8,
        generation: u64,
        fn current(ctx: *anyopaque) bool {
            const self: *DiagnosticGate = @ptrCast(@alignCast(ctx));
            return self.server.state.current(self.uri, self.generation);
        }
    };
    fn deinit(self: *Batch) void {
        const state = &self.server.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        for (self.replies.items) |reply| {
            reply.id.deinit(state.allocator);
            if (reply.body == .view) reply.body.view.release(state.allocator);
        }
        self.replies.deinit(state.allocator);
        self.replies = .empty;
    }
};

/// One protocol event loop advances both streams. The worker only queues frames.
pub fn run(io: std.Io, allocator: std.mem.Allocator, html_allocator: std.mem.Allocator) !bool {
    var transport = try output.Transport.init();
    defer transport.deinit();
    var queue: output.Queue = .{ .allocator = allocator, .io = io, .wake_fd = transport.wake[1] };
    defer queue.deinit();
    var server: Server = .{ .state = .{ .html_allocator = html_allocator, .allocator = allocator, .io = io }, .output = &queue };
    defer server.deinit();
    // Closing output first wakes a worker waiting for encoding credits on error.
    errdefer queue.close();
    var intake: framing.Intake = .{};
    defer intake.deinit(allocator);
    var intake_priority = false;
    defer server.state.releaseIntake(&intake_priority);
    var exit_requested = false;
    while (true) {
        var progressed = false;
        if (queue.peek()) |frame| {
            if (!frame.started() and frame.tag != null) {
                const tag = frame.tag.?;
                var gate: Batch.DiagnosticGate = .{ .server = &server, .uri = tag.uri, .generation = tag.generation };
                if (!Batch.DiagnosticGate.current(&gate)) {
                    queue.discard(frame);
                    continue;
                }
            }
            progressed = try queue.advance(1);
        }
        const incoming = try intake.step(allocator, 0);
        if (intake.length) |n| if (!intake_priority) server.state.beginIntake(n, &intake_priority);
        switch (incoming) {
            .pending => {},
            .eof => break,
            .packet => |bytes| {
                if (!intake_priority) server.state.beginIntake(bytes.len, &intake_priority);
                defer server.state.releaseIntake(&intake_priority);
                var packet: ?[]u8 = bytes;
                defer if (packet) |owned| allocator.free(owned);
                var parsed: json_message.Message = .{ .allocator = allocator };
                defer parsed.deinit();
                const decoding = if (build_options.json_storage == .inplace) parsed.parseInPlace(bytes) else parsed.parse(bytes, if (build_options.json_storage == .buffer) .buffer else .arena);
                decoding catch |err| {
                    try responses.failure(allocator, .{ .queue = &queue, .control = true }, .null, if (err == error.OutOfMemory) lsp.ErrorCode.internal_error else lsp.ErrorCode.parse_error, if (err == error.OutOfMemory) "Message storage exhausted" else "Parse error");
                    continue;
                };
                if (try server.handle(&parsed, &packet)) {
                    exit_requested = true;
                    break;
                }
                progressed = true;
            },
        }
        if (queue.isClosed()) return error.OutputClosed;
        if (!progressed and !intake.progressed) try transport.wait(true, queue.peek() != null, -1);
    }
    queue.close();
    // stop is idempotent at the application boundary; join before draining frames.
    server.deinit();
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (queue.peek()) |frame| {
        if (!frame.started() and frame.tag != null) {
            queue.discard(frame);
            continue;
        }
        _ = try queue.advance(1);
        if (std.Io.Timestamp.compare(std.Io.Clock.awake.now(io), .gte, deadline)) return error.OutputDrainTimeout;
        if (queue.peek() != null) try transport.wait(false, true, 10);
    }
    return exit_requested and !server.shutdown;
}

test "output pressure returns a resource error and releases its feature reader" {
    const a = std.testing.allocator;
    var queue: output.Queue = .{ .allocator = a, .io = std.testing.io, .config = .{ .frames = 0 } };
    defer queue.deinit();
    var server: Server = .{ .state = .{ .allocator = a, .html_allocator = a, .io = std.testing.io }, .output = &queue };
    var batch: Batch = .{ .server = &server };
    defer batch.deinit();
    const owner = try @import("runtime/snapshot.zig").References.create(a, .{}, "uri", 1, 1, 0, &server.state.index_bytes, 1024);
    try batch.add(.{ .integer = 7 }, .{ .view = .{ .references = .{ .index = owner, .point = .{ .line = 0, .character = 0 }, .include = true } } });
    owner.release(a);
    try batch.flush();
    batch.deinit();
    try std.testing.expectEqual(@as(usize, 0), server.state.index_bytes);
    const frame = queue.peek().?;
    try std.testing.expect(frame.control);
    try std.testing.expect(std.mem.indexOf(u8, frame.chunks.items[0].bytes[0..frame.chunks.items[0].used], "-32803") != null);
}

test "retired analysis failure does not start an obsolete diagnostic frame" {
    const a = std.testing.allocator;
    var queue: output.Queue = .{ .allocator = a, .io = std.testing.io };
    defer queue.deinit();
    var server: Server = .{ .state = .{ .allocator = a, .html_allocator = a, .io = std.testing.io }, .output = &queue };
    var batch: Batch = .{ .server = &server };
    defer batch.deinit();
    try Batch.analysisFailed(&batch, "closed:uri", 1, 1);
    try batch.flush();
    try std.testing.expect(queue.peek() == null);
}
