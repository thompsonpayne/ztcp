const std = @import("std");
const utils = @import("http_utils.zig");
const HttpMethod = utils.HttpMethod;
const HttpVersion = utils.HttpVersion;

const HttpRequest = @This();
arena: std.heap.ArenaAllocator,
allocator: std.mem.Allocator,
method: HttpMethod,
headers: std.StringHashMap([]const u8),
path: []const u8,
version: HttpVersion,
body: std.ArrayList(u8),
params: std.StringHashMap([]const u8),

pub fn init(allocator: std.mem.Allocator) !HttpRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const alloc = arena.allocator();

    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .allocator = alloc,
        .method = .UNKNOWN,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .path = "/",
        .version = HttpVersion.Http1_1,
        .body = try std.ArrayList(u8).initCapacity(allocator, 4096),
        .params = std.StringHashMap([]const u8).init(allocator),
    };
}

pub fn deinit(self: *HttpRequest) void {
    // self.headers.deinit();
    // self.params.deinit();
    // self.body.deinit(self.allocator);
    self.arena.deinit();
}

pub fn isBodyRequired(self: HttpRequest) bool {
    return switch (self.method) {
        .PUT, .PATCH, .POST => true,
        else => false,
    };
}

pub fn parseMethod(method_str: []const u8) HttpMethod {
    if (std.mem.eql(u8, method_str, "GET")) return HttpMethod.GET;
    if (std.mem.eql(u8, method_str, "POST")) return HttpMethod.POST;
    if (std.mem.eql(u8, method_str, "PUT")) return HttpMethod.PUT;
    if (std.mem.eql(u8, method_str, "PATCH")) return HttpMethod.PATCH;
    if (std.mem.eql(u8, method_str, "DELETE")) return HttpMethod.DELETE;
    if (std.mem.eql(u8, method_str, "UNKNOWN")) return HttpMethod.UNKNOWN;
    return HttpMethod.UNKNOWN;
}

/// Process request line.
///
/// Eg: "/POST /login HTTP/1.1\r\n".
///
/// Assign to self.method, self.version, self.path.
pub fn processRequestLine(self: *HttpRequest, request_line: []const u8) !void {
    var split_iter = std.mem.splitScalar(u8, request_line, ' ');

    const m = split_iter.first();
    const method = HttpRequest.parseMethod(m);

    const p = split_iter.next() orelse "/";
    const path = try self.allocator.dupe(u8, p);
    errdefer self.allocator.free(path);

    const v = split_iter.next() orelse "HTTP/1.1";
    const version = try HttpVersion.fromString(v);

    self.*.method = method;
    self.*.version = version;
    self.*.path = path;
}

/// Helper to get param value.
pub fn getParam(self: *const HttpRequest, key: []const u8) ?[]const u8 {
    return self.params.get(key);
}
