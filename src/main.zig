const std = @import("std");
const HttpParser = @import("http_parser.zig");
const testing = std.testing;
const net = std.net;
const PORT = 5882;

const Job = struct {
    connection: net.Server.Connection,
};

// "but we've threadpool at home"
// threadpool at home:
const ThreadPool = struct {
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    threads: []std.Thread,
    is_running: bool,
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Job),

    fn init(allocator: std.mem.Allocator, n_threads: u16) !*ThreadPool {
        const pool = try allocator.create(ThreadPool);
        pool.mutex = .{};
        pool.condition = .{};
        pool.queue = try std.ArrayList(Job).initCapacity(allocator, 128);
        pool.is_running = true;
        pool.allocator = allocator;

        pool.threads = try allocator.alloc(std.Thread, n_threads);

        for (0..n_threads) |i| {
            pool.threads[i] = try std.Thread.spawn(.{}, worker, .{pool});
        }

        return pool;
    }

    fn deinit(self: *ThreadPool) void {
        self.allocator.destroy(self);
    }

    fn addJob(self: *ThreadPool, conn: net.Server.Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, .{ .connection = conn });

        // wake up samurai, we've got a server to burn
        self.condition.signal();
    }

    fn worker(self: *ThreadPool) void {
        while (true) {
            self.mutex.lock();

            while (self.queue.items.len == 0 and self.is_running) {
                self.condition.wait(&self.mutex);
            }

            if (self.is_running and self.queue.items.len == 0) {
                self.mutex.unlock();
                return;
            }

            // pop the job
            const job = self.queue.orderedRemove(0);

            self.mutex.unlock();
            //do the work
            handleConnection(job.connection);
        }
    }
};

fn handleConnection(allocator: std.mem.Allocator, connection: net.Server.Connection) void {
    // NOTE: example of a request
    // POST /login HTTP/1.1\r\n
    // Host: example.com\r\n
    // User-Agent: Mozilla/5.0\r\n
    // Content-Type: application/json\r\n
    // Content-Length: 18\r\n
    // \r\n
    // {"user": "admin"}

    defer {
        std.log.info("[INFO] Client disconnected: {d}", .{connection.address.getPort()});
        connection.stream.close();
    }

    std.log.info("Client connected: {d}", .{connection.address.getPort()});

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
            error.EndOfStream => {
                std.debug.print("[INFO] Client sent EOS (Disconnect).\n", .{});
                break;
            },
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
        defer allocator.free(request_line_parsed.path);
        defer allocator.free(request_line_parsed.version);

        var content_length: u16 = 0;
        var headers = std.StringHashMap([]const u8).init(allocator); // for storing headers as kv
        defer headers.deinit();

        // CONSUME HEADERS
        while (true) {
            const header_slice = reader.takeDelimiterInclusive('\n') catch |err| {
                std.debug.print("[ERROR] Failed inside headers: {}\n", .{err});
                return; // Hard exit
            };
            const header = std.mem.trimEnd(u8, header_slice, "\r\n");

            if (header.len > 0) {
                var iter = std.mem.splitScalar(u8, header, ':');

                const key = iter.first();
                const value = iter.next() orelse "";
                const trimmed_value = std.mem.trim(u8, value, " ");
                headers.put(key, trimmed_value) catch |err| {
                    std.log.err("Invalid header {}\n", .{err});
                    return;
                };

                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    content_length = std.fmt.parseInt(u16, trimmed_value, 10) catch {
                        std.log.err("Invalid content length: {s}\n", .{trimmed_value});
                        return;
                    };
                }
            }

            if (header.len == 0) break;
        }

        std.debug.print("[DEBUG]  version: {s}\n", .{request_line_parsed.version});

        const request = HttpParser.HttpRequest.init(
            request_line_parsed.method,
            headers,
            request_line_parsed.path,
            request_line_parsed.version,
            null,
        ) catch |err| {
            std.log.err("[ERROR] construct request: {}\n", .{err});
            return;
        };

        std.debug.print("[LOGIC] Sending Response...\n", .{});
        const resp = std.mem.concat(allocator, u8, &[_][]const u8{
            @tagName(request.method),
            request.path,
            request.version,
        }) catch |err| {
            std.log.err("[ERROR] constructing response: {}\n", .{err});
            return;
        };
        errdefer allocator.free(resp);

        std.debug.print("[DEBUG] response: {s}\n", .{resp});

        writer.writeAll(resp) catch |err| {
            std.debug.print("[ERROR] Write Failed (Client gone?): {}\n", .{err});
            break;
        };

        writer.flush() catch |err| {
            std.log.err("flush error: {}\n", .{err});
        };

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

    std.debug.print("init with 4 threads\n", .{});

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
    method: HttpParser.HttpMethod,
    path: []const u8,
    version: []const u8,
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

test "test read until delimiter" {
    const str: []const u8 = "hello\n";
    var reader = std.Io.Reader.fixed(str);
    const result = try reader.takeDelimiterInclusive('\n');

    try testing.expectEqual(6, reader.seek);
    try testing.expectEqualStrings("hello\n", result);
}

test "trim right" {
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
