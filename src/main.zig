const std = @import("std");
const net = std.net;

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

fn handleConnection(connection: net.Server.Connection) void {
    // 1. This will print EXACTLY when the socket is closed and by whom.
    defer {
        std.log.info("[INFO] Client disconnected: {d}", .{connection.address.getPort()});
        connection.stream.close();
    }

    std.log.info("Client connected: {d}", .{connection.address.getPort()});

    var read_buf: [4096]u8 = undefined;
    var net_reader = std.net.Stream.Reader.init(connection.stream, &read_buf);
    const reader = &net_reader.file_reader.interface;

    var write_buf: [4096]u8 = undefined;
    var w = connection.stream.writer(&write_buf);
    var writer = &w.interface;

    while (true) {
        std.debug.print("\n[WAITING] Waiting for data...\n", .{});

        // READ REQUEST
        const line_slice = reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) {
                std.debug.print("[INFO] Client sent FIN (Disconnect).\n", .{});
            } else {
                std.debug.print("[ERROR] Read Error: {}\n", .{err});
            }
            break; // Breaks the loop -> Triggers defer -> Closes socket
        };

        const request_line = std.mem.trimRight(u8, line_slice, "\r\n");
        if (request_line.len == 0) {
            continue;
        }

        std.debug.print("[DATA] Request Line: '{s}'\n", .{request_line});

        // CONSUME HEADERS
        while (true) {
            const header_slice = reader.takeDelimiterInclusive('\n') catch |err| {
                std.debug.print("[ERROR] Failed inside headers: {}\n", .{err});
                return; // Hard exit
            };
            const header = std.mem.trimRight(u8, header_slice, "\r\n");

            if (header.len > 0) {
                std.debug.print("[DEBUG] Interpreting '{s}' as a Header for the previous request\n", .{header});
            }

            if (header.len == 0) break;
        }

        // TODO: HTTP parser
        // Parse "GET / HTTP/1.1"
        // var it = std.mem.splitScalar(u8, request_line, ' ');
        // const method = it.first();
        // const path = it.next() orelse "/";

        // SEND RESPONSE
        std.debug.print("[LOGIC] Sending Response...\n", .{});
        const msg =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 12\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n" ++
            "Hello World!";

        writer.writeAll(msg) catch |err| {
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

    const address = try std.net.Address.parseIp4("127.0.0.1", 5882);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening on 5882\n", .{});

    while (true) {
        const connection = try server.accept();
        // try pool.addJob(connection);

        real_pool.spawn(handleConnection, .{connection}) catch |err| {
            std.log.err("error handling connection: {}\n", .{err});
            connection.stream.close();
        };
    }
}
