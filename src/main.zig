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

    var server = try DServer.init(allocator, .{
        .host = "127.0.0.1",
        .n_threads = 4,
        .port = PORT,
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    // TODO: Call add routes here
    // Register dynamic route
    try server.get("/users/:id", handleGetUser);

    // Register nested dynamic route
    try server.get("/posts/:postId/comments/:commentId", handleComment);

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}

// TODO: implement detail
pub fn handleGetUser(allocator: std.mem.Allocator, conn: std.net.Server.Connection, req: HttpRequest) !void {
    _ = allocator;
    _ = conn;
    _ = req;
}

// TODO: implement detail
pub fn handleComment(allocator: std.mem.Allocator, conn: std.net.Server.Connection, req: HttpRequest) !void {
    _ = allocator;
    _ = conn;
    _ = req;
}
