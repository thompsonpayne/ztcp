const std = @import("std");
const HttpRequest = @import("http_request.zig");
const HttpResponse = @import("http_response.zig");
const DServer = @import("server.zig");
const ResponseBody = HttpResponse.ResponseBody;

const PORT = 5882;
const HOST = "127.0.0.1";

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leaking: \n", .{});
        }
    }

    const allocator = gpa.allocator();

    var server = try DServer.init(allocator, .{
        .host = HOST,
        .n_threads = 4,
        .port = PORT,
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    // Register dynamic route
    try server.get("/users/:id", handleGetUser);

    // Register nested dynamic route
    try server.get("/posts/:postId/comments/:commentId", handleComment);

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}

// TODO: implement detail
pub fn handleGetUser(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse) !void {
    _ = allocator;
    _ = req;
    res.status(200);

    const body: ResponseBody([]const u8) = .{
        .message = "Success getting user",
        .data = "Freaking bitching",
    };

    try res.json(body);
}

// TODO: implement detail
pub fn handleComment(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse) !void {
    _ = allocator;
    _ = req;

    res.status(200);
    try res.json("Success comment");
}
