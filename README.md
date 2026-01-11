<h1>Learning Zig TCP server</h1>
<h3>Zig version: 0.15.2</h3>

<h1>Todos</h1>

- [x] Setup connection handler.
- [x] Setup HttpRequest struct.
- [x] Setup HttpResponse struct.
- [x] Implement Server struct (HTTP Server).
  - [x] Handle connection timedout/idle time.
  - [x] Add route matching.
  - [x] Add middleware handling support, allow passing custom auth context.
  - [x] Add context for server/ route handlers, allow passing db instance inside context.
  - [x] Add pg db example.
  - [] Add auth example.
- [x] Parse headers:
  - [x] Parse request line.
  - [x] Parse headers.
  - [x] Parse content body.
  - [ ] Handle MIME tags?
- [x] Format response:
  - [x] Append correct headers.
  - [x] Append correct text content (plain text, json).

- Migrate to new IO interface when version 0.16 is tagged

Basic usage:

```zig
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

    const app_ctx: AppCtx = .{ .db = db };
    var server = try DServer.init(allocator, .{
        .host = HOST,
        .n_threads = 4,
        .port = PORT,
        .ctx = app_ctx,
    });
    defer server.deinit();

    std.debug.print("Listening at: {d}\n", .{PORT});

    var auth: Auth = undefined;
    try auth.init(allocator);
    defer auth.deinit();
    var auth_ctx = AuthCtx{
        .auth = &auth,
        .issuer = "zig-tcp",
        .audience = "zig-tcp-api",
        .ctx = &app_ctx,
    };

    try server.use(&auth_ctx, authHandler);

    // Register dynamic route
    try server.get("/tasks/:id", handleGetTask);

    // Register nested dynamic route
    try server.get("/posts/:postId/comments/:commentId", handleComment);

    server.serve() catch |err| {
        std.debug.print("[ERROR] from server: {}\n", .{err});
    };
}

pub fn handleGetTask(allocator: std.mem.Allocator, req: *const HttpRequest, res: *HttpResponse, ctx: *AppCtx) !void {
    _ = allocator;
    const db = ctx.db;
    const id = req.getParam("id");

    const body: ResponseBody([]const u8) = .{
        .message = "Success getting user",
        .data = "User A",
    };

    var row = try db.row("select name from tasks where id = $1", .{id}) orelse {
        res.status(.NotFound);
        try res.send("Not Found");
        return;
    };
    defer row.deinit() catch |err| {
        std.debug.print("Error cleaning up row query: {}", .{err});
    };

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
```

## Middleware

Middleware functions allow you to execute code before the final route handler. They can be used for authentication, logging, request modification, etc.

A middleware function must return a `MiddlewareResult` enum (defined in `server.zig`), which can be either:
- `.Continue`: Proceed to the next middleware or the route handler.
- `.Stop`: Stop processing the request (usually after sending a response).

### Defining a middleware

The middleware function signature accepts a context pointer, the matched route, the request, and the response.

```zig
const server_mod = @import("server.zig");

// Define your custom context if needed, or use any existing type
const MyMiddlewareCtx = struct {
    name: []const u8,
};

pub fn loggingMiddleware(
    ctx: *MyMiddlewareCtx,
    route: *const DServer.Route,
    req: *const HttpRequest,
    res: *HttpResponse,
) !server_mod.MiddlewareResult {
    _ = route;
    _ = res;
    std.debug.print("[{s}] Request: {s} {s}\n", .{ ctx.name, @tagName(req.method), req.path });

    // Return .Continue to let the request proceed
    return .Continue;
}
```

### Registering middleware

Use the `server.use` method to register middleware. You pass a pointer to your context and the middleware function.

```zig
    // ... inside main ...

    var my_ctx = MyMiddlewareCtx{ .name = "Logger" };

    // Register the middleware
    try server.use(&my_ctx, loggingMiddleware);
```

Note that the `ctx` passed to `server.use` must be a pointer. The middleware function will receive this pointer cast to the correct type.

## Route Handlers

Route handlers are functions that process HTTP requests and generate responses. You can register routes for different HTTP methods (GET, POST, PUT, DELETE, etc.) with dynamic path parameters.

### Registering routes

Use the server's HTTP method functions to register routes:

```zig
try server.get("/users/:id", handleGetUser);
try server.post("/users", handleCreateUser);
try server.put("/users/:id", handleUpdateUser);
try server.delete("/users/:id", handleDeleteUser);
```

### Handler function signature

Route handlers must have this signature:

```zig
pub fn handler(
    allocator: std.mem.Allocator,
    req: *const HttpRequest,
    res: *HttpResponse,
    ctx: *AppCtx,
) !void
```

- `allocator`: For any memory allocations needed in the handler
- `req`: The incoming HTTP request (contains method, path, headers, body, route params)
- `res`: The HTTP response builder (use to set status, headers, and send the response)
- `ctx`: Your application context (e.g., database connection pool, config, etc.)

### Accessing route parameters

Dynamic route segments are defined with `:paramName` and accessed via `req.getParam`:

```zig
try server.get("/posts/:postId/comments/:commentId", handleComment);

pub fn handleComment(
    allocator: std.mem.Allocator,
    req: *const HttpRequest,
    res: *HttpResponse,
    ctx: *AppCtx,
) !void {
    _ = allocator;
    _ = ctx;

    const postId = req.getParam("postId") orelse "";
    const commentId = req.getParam("commentId") orelse "";

    // Use the parameters...
    res.status(.OK);
    try res.json(.{ .postId = postId, .commentId = commentId });
}
```

### Sending responses

Set the status and send a response body:

```zig
// Send plain text
res.status(.OK);
try res.send("Hello, World!");

// Send JSON
res.status(.OK);
try res.json(.{ .message = "Success", .data = "some data" });

// Handle errors
res.status(.NotFound);
try res.send("Resource not found");
```

### Example handler with database

```zig
pub fn handleGetTask(
    allocator: std.mem.Allocator,
    req: *const HttpRequest,
    res: *HttpResponse,
    ctx: *AppCtx,
) !void {
    _ = allocator;
    const db = ctx.db;
    const id = req.getParam("id");

    var row = try db.row("select name from tasks where id = $1", .{id}) orelse {
        res.status(.NotFound);
        try res.send("Not Found");
        return;
    };
    defer row.deinit() catch |err| {
        std.debug.print("Error cleaning up row: {}\n", .{err});
    };

    res.status(.OK);
    try res.json(.{ .message = "Success", .data = row.get([]const u8, "name") });
}
```
