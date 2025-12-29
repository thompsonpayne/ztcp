const std = @import("std");
const HttpParser = @import("http_parser.zig");
const DServer = @import("server.zig");

const HttpRequest = HttpParser.HttpRequest;
const HttpMethod = HttpParser.HttpMethod;
const testing = std.testing;
const net = std.net;
const PORT = 5882;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leaking: \n", .{});
        }
    }

    const allocator = gpa.allocator();
    var server = try DServer.init(allocator, .{
        .host = "127.0.0.1",
        .n_threads = 4,
        .port = PORT,
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    // TODO: Call add routes here

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}
