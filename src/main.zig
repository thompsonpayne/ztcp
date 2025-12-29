const std = @import("std");
const HttpParser = @import("http_parser.zig");
const server_mod = @import("server.zig");
const DServer = server_mod.DServer;

const HttpRequest = HttpParser.HttpRequest;
const HttpMethod = HttpParser.HttpMethod;
const testing = std.testing;
const net = std.net;
const PORT = 5882;

const Routes = enum {
    Login,
    Home,
    Health,
    NotFound,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leaking: \n", .{});
        }
    }

    const allocator = gpa.allocator();

    var server = try DServer(Routes).init(allocator, .{
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
