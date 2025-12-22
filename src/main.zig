const std = @import("std");
const net = std.net;
const posix = std.posix;
const client_mod = @import("client.zig");
const server_mod = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("leaking!", .{});
        }
    }
    const allocator = gpa.allocator();

    var server = try server_mod.Server.init(allocator, 4096);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5881);
    try server.run(address);
}

fn printAddress(socket: posix.socket_t) !void {
    var address: std.net.Address = undefined;
    var len: posix.socklen_t = @sizeOf(net.Address);

    try posix.getsockname(socket, &address.any, &len);
}
