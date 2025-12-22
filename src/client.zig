const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    reader: Reader,

    pub fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        return .{
            .address = address,
            .reader = reader,
            .socket = socket,
        };
    }

    pub fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);
    }

    pub fn _handle(self: Client) !void {
        const socket = self.socket;
        const address = self.address;
        defer posix.close(socket);

        std.debug.print("{f} connected\n", .{address});

        const timeout = posix.timeval{ .sec = 2, .usec = 500_000 };

        // set read timeout
        try posix.setsockopt(
            socket,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            &std.mem.toBytes(timeout),
        );

        // set write timeout
        try posix.setsockopt(
            socket,
            posix.SOL.SOCKET,
            posix.SO.SNDTIMEO,
            &std.mem.toBytes(timeout),
        );

        var buf: [1024]u8 = undefined;
        var reader = Reader{
            .pos = 0,
            .buf = &buf,
            .socket = socket,
        };

        while (true) {
            const msg = try reader.readMessage();
            std.debug.print("msg: {s}\n", .{msg});
        }
    }

    pub fn handle(self: Client) void {
        self._handle() catch |err| {
            std.debug.print("err handling reader: {}\n", .{err});
        };
    }

    pub fn readMesage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }
};

const Reader = struct {
    // read message into this and where to look for a complete message
    buf: []u8,

    // state to represent where in buf is read up to,
    // any subsequent reads need to start from here
    pos: usize = 0,

    // where next message starts at
    start: usize = 0,

    fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{ .buf = buf, .start = 0, .pos = 0 };
    }

    fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    pub fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;

        // loop until we've read a message or the connection was closed
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }

            // read from socket, read into buf from the end of where we have data (self.pos)
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }

            self.pos = pos + n;
        }
    }

    // Checks if there's a full message in self.buf already.
    // If there isn't, checks that we have enough spare space in self.buf for
    // the next message.
    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        // pos - start represents bytes that we've read from the socket
        // but that we haven't yet returned as a "message" - possibly because
        // its incomplete.
        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];

        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }

        // len of message
        const message_len = std.mem.readInt(
            u32,
            unprocessed[0..4],
            .little,
        );

        // len of message + prefix len
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            // we have enough space, return
            return;
        }

        // At this point, we know that our buffer is larger enough for the data
        // we want to read, but we don't have enough spare space. We need to
        // "compact" our buffer, moving any unprocessed data back to the start
        // of the buffer.
        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};
