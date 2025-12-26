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
    defer connection.stream.close();
    std.log.info("At port: {d}\n", .{connection.address.getPort()});

    const msg = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello World!\n";
    var buf: [4096]u8 = undefined;
    var writer = connection.stream.writer(&buf);
    const wInterface = &writer.interface;
    _ = wInterface.write(msg) catch {};

    // don't forget to flush
    wInterface.flush() catch {};
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
