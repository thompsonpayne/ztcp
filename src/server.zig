/// HTTP Server
const std = @import("std");
const testing = std.testing;
const net = std.net;
const HttpParser = @import("http_parser.zig");
const HttpRequest = HttpParser.HttpRequest;
const HttpMethod = HttpParser.HttpMethod;
const HttpVersion = HttpParser.HttpVersion;

pub const DServer = @This();

allocator: std.mem.Allocator,
pool: std.Thread.Pool = undefined,
port: u16,
host: []const u8,
server: std.net.Server,
is_listening: bool = false,

/// Default port: 3000
pub fn init(allocator: std.mem.Allocator, comptime options: Options) !*DServer {
    const self = try allocator.create(DServer);
    errdefer allocator.destroy(self);

    try self.pool.init(.{ .allocator = allocator, .n_jobs = options.n_threads orelse 1 });

    self.server = undefined;
    self.allocator = allocator;
    self.port = options.port orelse 3000;
    self.host = options.host orelse "127.0.0.1";

    return self;
}

pub fn deinit(self: *DServer) void {
    self.pool.deinit();

    if (self.is_listening) {
        self.server.deinit();
    }

    self.is_listening = false;
    self.allocator.destroy(self);
}

pub fn serve(self: *DServer) !void {
    const address = try std.net.Address.parseIp4(self.host, self.port);
    self.server = try address.listen(.{ .reuse_address = true });
    self.is_listening = true;

    while (true) {
        const connection = try self.server.accept();
        // try pool.addJob(connection);

        self.pool.spawn(handleConnection, .{ self.allocator, connection }) catch |err| {
            std.log.err("error handling connection: {}\n", .{err});
            connection.stream.close();
        };
    }
}

pub fn handleConnection(allocator: std.mem.Allocator, connection: net.Server.Connection) void {
    _handleConnection(allocator, connection) catch |err| {
        std.debug.print("[ERROR] handle connection: {}\n", .{err});
        return;
    };
}

pub fn _handleConnection(allocator: std.mem.Allocator, connection: net.Server.Connection) !void {
    // NOTE: example of a request
    // POST /login HTTP/1.1\r\n
    // Host: example.com\r\n
    // User-Agent: Mozilla/5.0\r\n
    // Content-Type: application/json\r\n
    // Content-Length: 18\r\n
    // \r\n
    // {"user": "admin"}

    defer {
        std.log.debug("[INFO] Client disconnected: {d}", .{connection.address.getPort()});
        connection.stream.close();
    }

    std.log.debug("Client connected: {d}", .{connection.address.getPort()});

    var read_buf: [4096]u8 = undefined;
    // var net_reader = std.net.Stream.Reader.init(connection.stream, &read_buf);
    // const reader = &net_reader.file_reader.interface;

    var s_reader = connection.stream.reader(&read_buf);
    var reader = &s_reader.file_reader.interface;

    var write_buf: [4096]u8 = undefined;
    var w = connection.stream.writer(&write_buf);
    var writer = &w.interface;

    while (true) {
        // NOTE: request line example
        // POST /login HTTP/1.1\r\n

        std.debug.print("\n[WAITING] Waiting for data...\n", .{});

        var request = try HttpRequest.init(allocator);
        defer request.deinit();

        // READ REQUEST
        const line_slice = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            // Breaks the loop -> Triggers defer -> Closes socket
            error.EndOfStream => break,
            else => {
                std.debug.print("[ERROR] Read Error: {}\n", .{err});
                break;
            },
        };

        const request_line = std.mem.trimEnd(u8, line_slice, "\r\n");
        if (request_line.len == 0) {
            continue;
        }

        // process request line
        request.processRequestLine(request_line) catch |err| {
            std.log.err("[ERROR] process request line with error: {}\n", .{err});
            return;
        };
        defer {
            allocator.free(request.path);
        }

        if (request.method == .UNKNOWN) {
            try writer.writeAll("HTTP/1.1 405 ERROR\r\n");
            try writer.writeAll("Unknown method\r\n");
            try writer.flush();
            continue;
        }

        var content_length: u16 = 0;

        // HEADERS PARSING
        while (true) {
            const header_slice = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // NOTE: Keep headers small as restriction
                    std.debug.print("[ERROR] 431 Request header too large: {}\n", .{err});
                    return;
                },
                else => {
                    std.debug.print("[ERROR] Failed inside headers: {}\n", .{err});
                    return; // Hard exit
                },
            };
            const header = std.mem.trimEnd(u8, header_slice, "\r\n");

            if (header.len > 0) {
                var iter = std.mem.splitScalar(u8, header, ':');

                const key = iter.first();
                const value = iter.rest(); // handle case where value is: "localhost:8080"
                const trimmed_value = std.mem.trim(u8, value, " ");
                request.headers.put(key, trimmed_value) catch |err| {
                    std.log.err("Invalid header {}\n", .{err});
                    return;
                };

                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    content_length = std.fmt.parseInt(u16, trimmed_value, 10) catch 0;
                }
            }

            if (header.len == 0) break;
        }

        if (request.isBodyRequired() and content_length == 0) {
            try writer.writeAll("HTTP/1.1 400 Bad Request\r\n");
            try writer.writeAll("Empty payload \r\n");
            try writer.flush();
            continue;
        }

        if (content_length > 0) {
            // body = reader.readAlloc(allocator, content_length) catch null;
            std.debug.print("[debug] Reading {d} bytes of body...\n", .{content_length});

            var total_read: usize = 0;
            var body_buffer: [4096]u8 = undefined;

            // stream body in chunks to handle large body
            while (total_read < content_length) {
                const remaining = content_length - total_read;
                const to_read = @min(body_buffer.len, remaining);
                const dest_slice = body_buffer[0..to_read];

                const bytes_read = reader.readSliceShort(dest_slice) catch 0;

                if (bytes_read == 0) {
                    std.debug.print("[ERROR] Unexpected EOF. Expected {} more bytes.\n", .{remaining});
                    break;
                }

                const chunk = dest_slice[0..bytes_read];

                request.body.appendSlice(allocator, chunk) catch |err| {
                    std.debug.print("[ERROR] append chunk to body: {}\n", .{err});
                    return;
                };

                total_read += bytes_read;
            }
        }

        // TODO: handle routes
        // const route = request.getRoute();

        std.debug.print("[LOGIC] Sending Response...\n", .{});

        // Format response
        const response_body = request.body.items;
        try writer.writeAll("HTTP/1.1 200 OK\r\n");
        try writer.print("Content-Length: {d}\r\n", .{response_body.len});
        try writer.writeAll("Content-Type: text/plain\r\n");
        try writer.writeAll("Connection: keep-alive\r\n");

        try writer.writeAll("\r\n");

        writer.writeAll(response_body) catch |err| {
            std.debug.print("[ERROR] Write Failed (Client gone?): {}\n", .{err});
            break;
        };

        try writer.flush();
        std.debug.print("[SUCCESS] Response sent.\n", .{});
    }
}

const Options = struct {
    port: ?u16 = null,
    n_threads: ?u8 = null,
    host: ?[]const u8 = null,
};

test "read until delimiter" {
    const str: []const u8 = "hello\n";
    var reader = std.Io.Reader.fixed(str);
    const result = try reader.takeDelimiterInclusive('\n');

    try testing.expectEqual(6, reader.seek);
    try testing.expectEqualStrings("hello\n", result);
}

test "trim end" {
    const slice: []const u8 = "hello\r\n";
    const request_line = std.mem.trimEnd(u8, slice, "\r\n");

    try testing.expectEqualStrings("hello", request_line);
}

test "trim" {
    const slice: []const u8 = " 12";
    const header_value = std.mem.trim(u8, slice, " ");

    try testing.expectEqualStrings("12", header_value);
}

test "request line parse" {
    const allocator = testing.allocator;
    const request_line: []const u8 = "POST /login HTTP/1.1";

    var request = try HttpRequest.init(allocator);
    defer request.deinit();
    try request.processRequestLine(request_line);
    defer {
        allocator.free(request.path);
        allocator.free(request.version);
    }

    try testing.expectEqualStrings("POST", @tagName(request.method));
    try testing.expectEqualStrings("/login", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version.asString());
}
