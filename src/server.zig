const std = @import("std");
const net = std.net;
const client_mod = @import("client.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

pub const Server = struct {
    allocator: Allocator,

    // The number of clients we currently have connected
    connected: usize,

    // polls[0] is always our listening socket
    polls: []posix.pollfd,

    // list of clients, only client[0..connected] are valid
    clients: []client_mod.Client,

    // This is always polls[1..] and it's used to so that we can manipulate
    // clients and client_polls together. Necessary because polls[0] is the
    // listening socket, and we don't ever touch that.
    client_polls: []posix.pollfd,

    pub fn init(allocator: Allocator, max: usize) !Server {
        // +1 for the listening socket
        const polls = try allocator.alloc(posix.pollfd, max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(client_mod.Client, max);
        errdefer allocator.free(clients);

        return .{
            .polls = polls,
            .allocator = allocator,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
    }

    pub fn run(self: *Server, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(
            listener,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        while (true) {
            _ = try posix.poll(self.polls[0 .. self.connected + 1], -1);

            if (self.polls[0].revents != 0) {
                self.accept(listener) catch |err| {
                    log.err("failed to accept: {}\n", .{err});
                };
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    i += 1;
                    continue;
                }

                var client = &self.clients[i];

                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    // this socket is ready to be read
                    while (true) {
                        const msg = client.readMesage() catch {
                            // we don't increment `i` when we remove the client
                            // because removeClient does a swap and puts the last
                            // client at position i
                            self.removeClient(i);
                            break;
                        } orelse {
                            // no more messages but this client still connects
                            i += 1;
                            break;
                        };
                        std.debug.print("got: {s}\n", .{msg});
                    }
                }
            }
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        while (true) {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(
                listener,
                &address.any,
                &address_len,
                posix.SOCK.NONBLOCK,
            ) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client = client_mod.Client.init(
                self.allocator,
                socket,
                address,
            ) catch |err| {
                posix.close(socket);
                log.err("failed to init client: {}\n", .{err});
                return;
            };

            const connected = self.connected;
            self.clients[connected] = client;
            self.client_polls[connected] = .{
                .revents = 0,
                .fd = socket,
                .events = posix.POLL.IN,
            };
            self.connected = connected + 1;
        }
    }

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        posix.close(client.socket);
        client.deinit(self.allocator);

        // Swap the client we're removing with the last one
        // So that when we set connected -= 1, it'll effectively "remove"
        // the client from our slices.
        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];

        self.connected = last_index;
    }
};
