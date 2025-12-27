const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    UNKNOWN,
};

pub const HttpRequest = struct {
    method: HttpMethod,
    headers: std.StringHashMap([]const u8),
    path: []const u8,
    version: []const u8,
    body: ?[]const u8,

    pub fn parseMethod(method_str: []const u8) HttpMethod {
        if (std.mem.eql(u8, method_str, "GET")) return HttpMethod.GET;
        if (std.mem.eql(u8, method_str, "POST")) return HttpMethod.POST;
        if (std.mem.eql(u8, method_str, "PUT")) return HttpMethod.PUT;
        if (std.mem.eql(u8, method_str, "DELETE")) return HttpMethod.DELETE;
        if (std.mem.eql(u8, method_str, "UNKNOWN")) return HttpMethod.UNKNOWN;
        return HttpMethod.UNKNOWN;
    }

    pub fn init(
        method: HttpMethod,
        headers: std.StringHashMap([]const u8),
        path: []const u8,
        version: []const u8,
        body: ?[]const u8,
    ) !HttpRequest {
        return .{
            .method = method,
            .headers = headers,
            .path = path,
            .version = version,
            .body = body,
        };
    }
};
