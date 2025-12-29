<h1>Learning Zig TCP server</h1>
<h3>Zig version: 0.15.2</h3>

<h1>Todos</h1>

- [x] Setup connection handler
- [x] Setup DServer struct (HTTP Server)
- [x] Parse headers:
  - [x] Parse request line
  - [x] Parse headers
  - [ ] Parse content body
- [ ] Format response:
  - [ ] Append correct headers
  - [ ] Append correct content

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
```
