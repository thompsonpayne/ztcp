const std = @import("std");
const pg = @import("pg");
const auth_mod = @import("auth.zig");
const utils = @import("http_utils.zig");
const HttpRequest = @import("http_request.zig");
const HttpResponse = @import("http_response.zig");
const server_mod = @import("server.zig");

const Auth = auth_mod.Auth;
const ResponseBody = HttpResponse.ResponseBody;

const PORT = 5882;
const HOST = "127.0.0.1";

const AuthCtx = struct {
    auth: *Auth, // contains jwt secret + refresh store + mutex
    issuer: []const u8,
    audience: []const u8,
};

const AppCtx = struct { db: *pg.Pool };
const DServer = server_mod.Server(AppCtx);
const Route = DServer.Route;

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

    var db = pg.Pool.init(allocator, .{
        .connect = .{ .port = 5433, .host = "localhost" },
        .auth = .{
            .username = "postgres",
            .database = "postgres",
            .password = "secret",
        },
    }) catch |err| {
        std.debug.print("Error connecting db: {}\n", .{err});
        return err;
    };
    defer db.deinit();

    var server = try DServer.init(allocator, .{
        .host = HOST,
        .n_threads = 4,
        .port = PORT,
        .ctx = .{ .db = db },
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    var auth: Auth = undefined;
    try auth.init(allocator);
    defer auth.deinit();
    var app_ctx = AuthCtx{
        .auth = &auth,
        .issuer = "zig-tcp",
        .audience = "zig-tcp-api",
    };

    try server.use(&app_ctx, authHandler);

    // Register dynamic route
    try server.get("/users/:id", handleGetUser);

    // Register nested dynamic route
    try server.get("/posts/:postId/comments/:commentId", handleComment);

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}

pub fn handleGetUser(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse, ctx: *AppCtx) !void {
    _ = allocator;
    _ = req;
    _ = ctx;

    const body: ResponseBody([]const u8) = .{
        .message = "Success getting user",
        .data = "User A",
    };

    // var row = try app.db.row("select name from tasks where id = $1", .{task_id}) orelse {
    //     res.status = 404;
    //     res.body = "Not Found";
    //     return;
    // };
    // defer row.deinit() catch |err| {
    //     std.debug.print("Error cleaning up row query: {}", .{err});
    // };

    res.status(utils.StatusCode.OK);
    try res.json(body);
}

pub fn handleComment(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse, ctx: *AppCtx) !void {
    _ = ctx;

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
) !server_mod.MiddlewareResult {
    _ = route;

    std.debug.print("[INFO] Authing ...", .{});
    const authn = try ctx.auth.authenticate(req);
    const authz = try ctx.auth.authorize(.any_authenticated, authn);

    std.debug.print("[INFO] Got auth info, checking auth", .{});
    switch (authz) {
        .allow => |maybe_principal| {
            _ = maybe_principal orelse return .Stop;
            return .Continue;
        },
        .unauthorized => {
            res.status(.Unauthorized);
            try res.json("Not authorized");
            return .Stop;
        },
        .forbidden => {
            res.status(.Forbidden);
            try res.json("Forbidden");
            return .Stop;
        },
    }

    std.debug.print("Issuer: {s}\n", .{ctx.issuer});
    return .Continue;
}
