//! Bounded owned frames. Only the protocol thread writes stdout; producers signal
//! its nonblocking wake pipe.
const std = @import("std");
const posix = std.posix;
pub const Role = enum { dispatcher, worker };
pub const Config = struct {
    bytes: usize = 144 * 1024 * 1024,
    frames: usize = 256,
    body: usize = 128 * 1024 * 1024,
    control_bytes: usize = 512 * 1024,
    control_frames: usize = 64,
};
const bulk_metadata = 256 * 1024;
const control_metadata = 16 * 1024;
pub const Tag = struct { uri: []const u8, generation: u64 };
const Chunk = struct { bytes: []u8, used: usize = 0 };
pub const Frame = struct {
    next: ?*Frame = null,
    chunks: std.ArrayList(Chunk) = .empty,
    tag: ?Tag = null,
    control: bool,
    charged: usize,
    header: [64]u8 = undefined,
    header_len: usize = 0,
    header_at: usize = 0,
    chunk_at: usize = 0,
    byte_at: usize = 0,
    pub fn started(self: *const Frame) bool {
        return self.header_at != 0;
    }
};
pub const Queue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config = .{},
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    head: ?*Frame = null,
    tail: ?*Frame = null,
    bytes: [2]usize = .{ 0, 0 },
    frames: [2]usize = .{ 0, 0 },
    closed: bool = false,
    wake_fd: ?posix.fd_t = null,
    fn index(control: bool) usize {
        return @intFromBool(control);
    }
    fn reserve(self: *Queue, n: usize, slot: bool, control: bool, role: Role) !void {
        const i = index(control);
        const cap = if (control) self.config.control_bytes else self.config.bytes;
        const slots = if (control) self.config.control_frames else self.config.frames;
        if (n > cap) return error.OutputBusy;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closed and (n > cap - self.bytes[i] or (slot and self.frames[i] == slots))) {
            if (role == .dispatcher) return error.OutputBusy;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.OutputClosed;
        self.bytes[i] += n;
        if (slot) self.frames[i] += 1;
    }
    fn giveBack(self: *Queue, n: usize, slot: bool, control: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = index(control);
        self.bytes[i] -= n;
        if (slot) self.frames[i] -= 1;
        self.condition.broadcast(self.io);
    }
    fn wake(self: *Queue) void {
        if (self.wake_fd) |fd| {
            _ = posix.system.write(fd, "x", 1);
        }
    }
    pub fn close(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.wake();
    }
    pub fn isClosed(self: *Queue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.closed;
    }
    pub fn enqueue(self: *Queue, frame: *Frame) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.OutputClosed;
        if (self.tail) |last| last.next = frame else self.head = frame;
        self.tail = frame;
        self.wake();
    }
    pub fn peek(self: *Queue) ?*Frame {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.head;
    }
    pub fn discard(self: *Queue, frame: *Frame) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.head == frame);
        self.head = frame.next;
        if (self.head == null) self.tail = null;
        self.mutex.unlock(self.io);
        self.destroy(frame);
    }
    pub fn destroy(self: *Queue, frame: *Frame) void {
        for (frame.chunks.items[frame.chunk_at..]) |chunk| self.allocator.free(chunk.bytes);
        frame.chunks.deinit(self.allocator);
        if (frame.tag) |tag| self.allocator.free(tag.uri);
        const charged = frame.charged;
        const control = frame.control;
        self.allocator.destroy(frame);
        self.giveBack(charged, true, control);
    }
    pub fn deinit(self: *Queue) void {
        self.close();
        while (self.peek()) |frame| self.discard(frame);
        std.debug.assert(self.bytes[0] == 0 and self.bytes[1] == 0);
        std.debug.assert(self.frames[0] == 0 and self.frames[1] == 0);
    }
    /// Nonblocking write progress, at most 64 KiB total. Caller checks a diagnostic's tag
    /// immediately before the first call. Once started, a frame cannot be skipped.
    pub fn advance(self: *Queue, fd: posix.fd_t) !bool {
        const frame = self.peek() orelse return false;
        var budget: usize = 64 * 1024;
        var progressed = false;
        while (budget != 0) {
            if (frame.header_at < frame.header_len) {
                const bytes = frame.header[frame.header_at..frame.header_len];
                const n = try writeSome(fd, bytes[0..@min(bytes.len, budget)]);
                if (n == 0) return progressed;
                frame.header_at += n;
                budget -= n;
                progressed = true;
                continue;
            }
            if (frame.chunk_at == frame.chunks.items.len) {
                self.discard(frame);
                return true;
            }
            const chunk = frame.chunks.items[frame.chunk_at];
            const bytes = chunk.bytes[frame.byte_at..chunk.used];
            const n = try writeSome(fd, bytes[0..@min(bytes.len, budget)]);
            if (n == 0) return progressed;
            frame.byte_at += n;
            budget -= n;
            progressed = true;
            if (frame.byte_at == chunk.used) {
                self.allocator.free(chunk.bytes);
                frame.charged -= chunk.bytes.len;
                self.giveBack(chunk.bytes.len, false, frame.control);
                frame.chunk_at += 1;
                frame.byte_at = 0;
            }
        }
        return progressed;
    }
};
pub const Builder = struct {
    queue: *Queue,
    role: Role,
    frame: ?*Frame,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush } },
    sealed: usize = 0,
    failure: anyerror = error.WriteFailed,
    pub fn init(queue: *Queue, role: Role, control: bool, tag: ?Tag) !Builder {
        const metadata: usize = if (control) control_metadata else bulk_metadata;
        try queue.reserve(metadata, true, control, role);
        errdefer queue.giveBack(metadata, true, control);
        const frame = try queue.allocator.create(Frame);
        errdefer queue.allocator.destroy(frame);
        frame.* = .{ .control = control, .charged = metadata };
        if (tag) |t| frame.tag = .{ .uri = try queue.allocator.dupe(u8, t.uri), .generation = t.generation };
        return .{ .queue = queue, .role = role, .frame = frame };
    }
    pub fn deinit(self: *Builder) void {
        if (self.frame) |f| self.queue.destroy(f);
    }
    fn limit(self: *Builder) usize {
        return if (self.frame.?.control) 64 * 1024 else self.queue.config.body;
    }
    fn next(self: *Builder) !void {
        const frame = self.frame.?;
        if (frame.chunks.items.len != 0) {
            frame.chunks.items[frame.chunks.items.len - 1].used = self.writer.end;
            self.sealed += self.writer.end;
        }
        if (self.sealed >= self.limit()) return error.FrameTooLarge;
        const n = @min(if (frame.chunks.items.len == 0) @as(usize, 4096) else 64 * 1024, self.limit() - self.sealed);
        try self.queue.reserve(n, false, frame.control, self.role);
        errdefer self.queue.giveBack(n, false, frame.control);
        const bytes = try self.queue.allocator.alloc(u8, n);
        errdefer self.queue.allocator.free(bytes);
        try frame.chunks.append(self.queue.allocator, .{ .bytes = bytes });
        frame.charged += n;
        self.writer.buffer = bytes;
        self.writer.end = 0;
    }
    fn append(self: *Builder, bytes: []const u8) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            if (self.writer.end == self.writer.buffer.len) try self.next();
            const n = @min(bytes.len - at, self.writer.buffer.len - self.writer.end);
            @memcpy(self.writer.buffer[self.writer.end..][0..n], bytes[at..][0..n]);
            self.writer.end += n;
            at += n;
        }
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Builder = @fieldParentPtr("writer", w);
        var n: usize = 0;
        for (data, 0..) |part, i| {
            const count = if (i + 1 == data.len) splat else 1;
            for (0..count) |_| {
                self.append(part) catch |err| {
                    self.failure = err;
                    return error.WriteFailed;
                };
                n += part.len;
            }
        }
        return n;
    }
    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}
    pub fn finish(self: *Builder) !*Frame {
        const frame = self.frame.?;
        if (frame.chunks.items.len != 0) frame.chunks.items[frame.chunks.items.len - 1].used = self.writer.end;
        const length = self.sealed + self.writer.end;
        frame.header_len = (try std.fmt.bufPrint(&frame.header, "Content-Length: {d}\r\n\r\n", .{length})).len;
        self.frame = null;
        return frame;
    }
};

pub fn writeSome(fd: posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const n = posix.system.write(fd, bytes.ptr, bytes.len);
        switch (posix.errno(n)) {
            .SUCCESS => return @intCast(n),
            .INTR => continue,
            .AGAIN => return 0,
            else => return error.OutputFailed,
        }
    }
}
fn setFlags(fd: posix.fd_t, flags: usize) !void {
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags)) != .SUCCESS) return error.NonblockingFailed;
}
fn nonblocking(fd: posix.fd_t) !usize {
    const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(rc) != .SUCCESS) return error.NonblockingFailed;
    const flags: usize = @intCast(rc);
    const mask: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    try setFlags(fd, flags | mask);
    return flags;
}
pub const Transport = struct {
    wake: [2]posix.fd_t,
    input_flags: usize,
    output_flags: usize,
    pub fn init() !Transport {
        const wake = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer for (wake) |fd| {
            _ = posix.system.close(fd);
        };
        const input_flags = try nonblocking(0);
        errdefer setFlags(0, input_flags) catch {};
        const output_flags = try nonblocking(1);
        return .{ .wake = wake, .input_flags = input_flags, .output_flags = output_flags };
    }
    pub fn deinit(self: *Transport) void {
        setFlags(0, self.input_flags) catch {};
        setFlags(1, self.output_flags) catch {};
        for (self.wake) |fd| {
            _ = posix.system.close(fd);
        }
    }
    pub fn wait(self: *Transport, input: bool, output: bool, timeout: i32) !void {
        var fds = [_]posix.pollfd{
            .{ .fd = if (input) 0 else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (output) 1 else -1, .events = posix.POLL.OUT, .revents = 0 },
            .{ .fd = self.wake[0], .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, timeout);
        var bytes: [256]u8 = undefined;
        while (true) {
            const n = posix.read(self.wake[0], &bytes) catch break;
            if (n == 0) break;
        }
    }
};

test "chunk encoding handles boundaries, splats, frame caps and credit cleanup" {
    const a = std.testing.allocator;
    var q: Queue = .{ .allocator = a, .io = std.testing.io, .config = .{ .body = 100000 } };
    defer q.deinit();
    var b = try Builder.init(&q, .dispatcher, false, .{ .uri = "uri", .generation = 9 });
    defer b.deinit();
    try b.writer.splatByteAll('x', 70000);
    const frame = try b.finish();
    try q.enqueue(frame);
    var total: usize = 0;
    for (frame.chunks.items) |chunk| {
        total += chunk.used;
        for (chunk.bytes[0..chunk.used]) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
    }
    try std.testing.expectEqual(@as(usize, 70000), total);
    try std.testing.expectEqualStrings("Content-Length: 70000\r\n\r\n", frame.header[0..frame.header_len]);
    q.discard(frame);
    try std.testing.expectEqual(@as(usize, 0), q.bytes[0]);
    var limited = try Builder.init(&q, .dispatcher, false, null);
    defer limited.deinit();
    try std.testing.expectError(error.WriteFailed, limited.writer.splatByteAll('y', 100001));
    try std.testing.expectEqual(error.FrameTooLarge, limited.failure);
}

test "dispatcher rejects pressure while control reserve remains available" {
    var q: Queue = .{ .allocator = std.testing.allocator, .io = std.testing.io, .config = .{ .frames = 1 } };
    defer q.deinit();
    var first = try Builder.init(&q, .dispatcher, false, null);
    defer first.deinit();
    try std.testing.expectError(error.OutputBusy, Builder.init(&q, .dispatcher, false, null));
    var control = try Builder.init(&q, .dispatcher, true, null);
    defer control.deinit();
    try control.writer.writeAll("error reply");
    q.close();
    const frame = try control.finish();
    defer q.destroy(frame);
    try std.testing.expectError(error.OutputClosed, q.enqueue(frame));
}

test "all encoding allocation failures roll back reserved bytes and slots" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var q: Queue = .{ .allocator = a, .io = std.testing.io };
            defer q.deinit();
            var b = try Builder.init(&q, .dispatcher, false, .{ .uri = "uri", .generation = 1 });
            defer b.deinit();
            b.writer.splatByteAll('x', 90000) catch return b.failure;
            const frame = try b.finish();
            errdefer q.destroy(frame);
            try q.enqueue(frame);
        }
    }.run, .{});
}

test "closing output wakes a worker waiting for frame capacity" {
    var q: Queue = .{ .allocator = std.testing.allocator, .io = std.testing.io, .config = .{ .frames = 1 } };
    defer q.deinit();
    var held = try Builder.init(&q, .dispatcher, false, null);
    defer held.deinit();
    const Waiter = struct {
        queue: *Queue,
        entered: std.atomic.Value(bool) = .init(false),
        closed: bool = false,
        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            var b = Builder.init(self.queue, .worker, false, null) catch |err| {
                self.closed = err == error.OutputClosed;
                return;
            };
            b.deinit();
        }
    };
    var waiter: Waiter = .{ .queue = &q };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    while (!waiter.entered.load(.acquire)) std.Thread.yield() catch {};
    q.close();
    thread.join();
    try std.testing.expect(waiter.closed);
}
