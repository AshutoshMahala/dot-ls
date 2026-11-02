//! Stdio framing only. The application owns intake priority and packet lifetime.
const std = @import("std");
pub const max_message = 256 * 1024 * 1024;
pub fn readHeader(reader: *std.Io.Reader) !?usize {
    var length: ?usize = null;
    var header_bytes: usize = 0;
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream and header_bytes == 0) return null;
            return err;
        };
        if (try reader.takeByte() != '\n') return error.InvalidHeader;
        header_bytes += line.len + 1;
        if (header_bytes > 8192) return error.HeaderTooLarge;
        if (std.mem.eql(u8, line, "\r")) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Content-Length")) {
            if (length != null) return error.DuplicateLength;
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \r\t"), 10);
        }
    }
    const n = length orelse return error.MissingLength;
    if (n > max_message) return error.MessageTooLarge;
    return n;
}

pub fn readBody(reader: *std.Io.Reader, allocator: std.mem.Allocator, n: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, n);
    errdefer allocator.free(bytes);
    try reader.readSliceAll(bytes);
    return bytes;
}

test "framing preserves packet boundaries and header rules" {
    var reader = std.Io.Reader.fixed("content-length: 3\r\nOther: ignored\r\n\r\nabcContent-Length: 0\r\n\r\n");
    const length = (try readHeader(&reader)).?;
    try std.testing.expectEqual(@as(usize, 3), length);
    const bytes = try readBody(&reader, std.testing.allocator, length);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abc", bytes);
    try std.testing.expectEqual(@as(?usize, 0), try readHeader(&reader));
    try std.testing.expectEqual(@as(?usize, null), try readHeader(&reader));
    var duplicate = std.Io.Reader.fixed("Content-Length: 1\r\nContent-Length: 2\r\n\r\n");
    try std.testing.expectError(error.DuplicateLength, readHeader(&duplicate));
    var missing = std.Io.Reader.fixed("\r\n");
    try std.testing.expectError(error.MissingLength, readHeader(&missing));
    var oversized = std.Io.Reader.fixed("Content-Length: 268435457\r\n\r\n");
    try std.testing.expectError(error.MessageTooLarge, readHeader(&oversized));
    var invalid = std.Io.Reader.fixed("invalid\r\n");
    try std.testing.expectError(error.InvalidHeader, readHeader(&invalid));
}

test "truncated packets and allocation failures release body storage" {
    var truncated = std.Io.Reader.fixed("ab");
    try std.testing.expectError(error.EndOfStream, readBody(&truncated, std.testing.allocator, 3));
    var reader = std.Io.Reader.fixed("abc");
    try std.testing.expectError(error.OutOfMemory, readBody(&reader, std.testing.failing_allocator, 3));
    var incomplete_header = std.Io.Reader.fixed("Content-Length: 3\r\n");
    try std.testing.expectError(error.EndOfStream, readHeader(&incomplete_header));
}

/// Incremental intake. Owns one exact body allocation; never reads into the next
/// packet. A partial header/body yields to output and worker wakeups.
pub const Intake = struct {
    header: [8192]u8 = undefined,
    header_len: usize = 0,
    length: ?usize = null,
    body: ?[]u8 = null,
    at: usize = 0,
    progressed: bool = false,
    pub const Result = union(enum) { pending, eof, packet: []u8 };
    pub fn deinit(self: *Intake, allocator: std.mem.Allocator) void {
        if (self.body) |body| allocator.free(body);
    }
    pub fn step(self: *Intake, allocator: std.mem.Allocator, fd: std.posix.fd_t) !Result {
        self.progressed = false;
        var read: usize = 0;
        while (read < 256 * 1024) {
            if (self.length) |n| {
                if (self.body == null) self.body = try allocator.alloc(u8, n);
                if (self.at == n) {
                    const body = self.body.?;
                    self.body = null;
                    self.at = 0;
                    self.length = null;
                    self.header_len = 0;
                    return .{ .packet = body };
                }
                const count = std.posix.read(fd, self.body.?[self.at..][0..@min(n - self.at, 256 * 1024 - read)]) catch |err| {
                    if (err == error.WouldBlock) return .pending;
                    return err;
                };
                if (count == 0) return error.EndOfStream;
                self.at += count;
                read += count;
                self.progressed = true;
            } else {
                if (self.header_len == self.header.len) return error.HeaderTooLarge;
                const count = std.posix.read(fd, self.header[self.header_len..][0..1]) catch |err| {
                    if (err == error.WouldBlock) return .pending;
                    return err;
                };
                if (count == 0) return if (self.header_len == 0) .eof else error.EndOfStream;
                self.header_len += 1;
                read += 1;
                self.progressed = true;
                const h = self.header[0..self.header_len];
                if (h[h.len - 1] == '\n') {
                    const start = if (std.mem.lastIndexOfScalar(u8, h[0 .. h.len - 1], '\n')) |v| v + 1 else 0;
                    const line = h[start..];
                    if (std.mem.eql(u8, line, "\r\n")) {
                        var reader = std.Io.Reader.fixed(h);
                        self.length = (try readHeader(&reader)).?;
                    } else if (std.mem.indexOfScalar(u8, line, ':') == null) return error.InvalidHeader;
                }
            }
        }
        return .pending;
    }
};
