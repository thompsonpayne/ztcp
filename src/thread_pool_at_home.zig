const std = @import("std");
const net = std.net;
const main = @import("main.zig");

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
            main.handleConnection(self.allocator, job.connection);
        }
    }
};
