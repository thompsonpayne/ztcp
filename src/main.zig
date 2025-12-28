const std = @import("std");
const HttpParser = @import("http_parser.zig");
const testing = std.testing;
const net = std.net;
const PORT = 5882;

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
        const request_line_parsed = processRequestLine(allocator, request_line) catch |err| {
            std.log.err("[ERROR] process request line with error: {}\n", .{err});
            return;
        };
        defer {
            allocator.free(request_line_parsed.path);
            allocator.free(request_line_parsed.version);
        }

        var content_length: u16 = 0;
        var headers = std.StringHashMap([]const u8).init(allocator); // for storing headers as kv
        defer headers.deinit();

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
                headers.put(key, trimmed_value) catch |err| {
                    std.log.err("Invalid header {}\n", .{err});
                    return;
                };

                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    content_length = std.fmt.parseInt(u16, trimmed_value, 10) catch 0;
                }
            }

            if (header.len == 0) break;
        }

        var body = try std.ArrayList(u8).initCapacity(allocator, 1024);

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

                body.appendSlice(allocator, chunk) catch |err| {
                    std.debug.print("[ERROR] append chunk to body: {}\n", .{err});
                    return;
                };

                total_read += bytes_read;
            }
        }
        defer body.deinit(allocator);

        // TODO: handle routes

        std.debug.print("[LOGIC] Sending Response...\n", .{});

        // Format response
        const response_body = body.items;
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

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leaking: \n", .{});
        }
    }
    const allocator = gpa.allocator();

    // const pool = try ThreadPool.init(allocator, 4);
    var real_pool: std.Thread.Pool = undefined;
    try real_pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer real_pool.deinit();

    std.debug.print("[INFO] init with 4 threads\n", .{});

    const address = try std.net.Address.parseIp4("127.0.0.1", PORT);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening on {d}\n", .{PORT});

    while (true) {
        const connection = try server.accept();
        // try pool.addJob(connection);

        real_pool.spawn(handleConnection, .{ allocator, connection }) catch |err| {
            std.log.err("error handling connection: {}\n", .{err});
            connection.stream.close();
        };
    }
}

const RequestLine = struct {
    path: []const u8,
    version: []const u8,
    method: HttpParser.HttpMethod,
};

fn processRequestLine(allocator: std.mem.Allocator, request_line: []const u8) !RequestLine {
    var split_iter = std.mem.splitScalar(u8, request_line, ' ');
    const m = split_iter.first();
    const method = HttpParser.HttpRequest.parseMethod(m);
    const p = split_iter.next() orelse "/";
    const v = split_iter.next() orelse "HTTP/1.1";

    const path = try allocator.dupe(u8, p);
    errdefer allocator.free(path);

    const version = try allocator.dupe(u8, v);

    return .{ .method = method, .path = path, .version = version };
}

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
    const result = try processRequestLine(allocator, request_line);
    defer {
        allocator.free(result.path);
        allocator.free(result.version);
    }

    try testing.expectEqualStrings("POST", @tagName(result.method));
    try testing.expectEqualStrings("/login", result.path);
    try testing.expectEqualStrings("HTTP/1.1", result.version);
}
