const std = @import("std");
const Auth = @import("auth.zig");
const HttpRequest = @import("http_request.zig");
const HttpResponse = @import("http_response.zig");
const DServer = @import("server.zig");
const Route = DServer.Route;
const utils = @import("http_utils.zig");
const ResponseBody = HttpResponse.ResponseBody;

const PORT = 5882;
const HOST = "127.0.0.1";

const AuthCtx = struct {
    auth: *Auth.Auth, // contains jwt secret + refresh store + mutex
    issuer: []const u8,
    audience: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("leaking: \n", .{});
        }
    }

    const a = gpa.allocator();

    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = a };
    const allocator = tsa.allocator();

    var server = try DServer.init(allocator, .{
        .host = HOST,
        .n_threads = 4,
        .port = PORT,
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    var auth = Auth.Auth.init(allocator);
    defer auth.deinit();
    var auth_ctx = AuthCtx{ .auth = &auth, .issuer = "zig-tcp", .audience = "zig-tcp-api" };

    try server.use(&auth_ctx, authHandler);

    // Register dynamic route
    try server.get("/users/:id", handleGetUser);

    // Register nested dynamic route
    try server.get("/posts/:postId/comments/:commentId", handleComment);

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}

pub fn handleGetUser(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse) !void {
    _ = allocator;
    _ = req;

    const body: ResponseBody([]const u8) = .{
        .message = "Success getting user",
        .data = "User A",
    };

    res.status(utils.StatusCode.OK);
    try res.json(body);
}

pub fn handleComment(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse) !void {
    const postId = req.getParam("postId") orelse "";
    const commentId = req.getParam("commentId") orelse "";

    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer result.deinit(allocator);

    try result.print(allocator, "PostId: {s}, CommentId: {s}", .{ postId, commentId });

    res.status(utils.StatusCode.OK);
    try res.json(result.items);
}

pub fn authHandler(
    ctx: *AuthCtx,
    route: *const Route,
    req: *const HttpRequest,
    res: *HttpResponse,
) !DServer.MiddlewareResult {
    _ = ctx;
    _ = route;
    _ = req;
    _ = res;
    return .Continue;
}
