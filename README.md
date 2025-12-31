<h1>Learning Zig TCP server</h1>
<h3>Zig version: 0.15.2</h3>

<h1>Todos</h1>

- [x] Setup connection handler
- [x] Setup HttpRequest struct
- [x] Setup HttpResponse struct
- [x] Implement Server struct (HTTP Server)
  - [ ] Handle read/write timeout, close connection
  - [ ] Gracefully shutdown?
- [x] Parse headers:
  - [x] Parse request line
  - [x] Parse headers
  - [x] Parse content body
- [x] Format response:
  - [x] Append correct headers
  - [x] Append correct text content (plain text, json)
  - [ ] Handle MIME tags?

Basic usage:

```zig
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
```
