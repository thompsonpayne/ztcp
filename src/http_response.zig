const std = @import("std");

const HttpResponse = @This();

const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub fn ResponseBody(comptime T: type) type {
    return struct { message: []const u8, data: T };
}

allocator: std.mem.Allocator,
status_code: u16, // TODO: Use enum later
headers: std.ArrayList(Header),
headers_sent: bool,

writer: *std.Io.Writer, // Zig 0.15 Io interface

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) !HttpResponse {
    return .{
        .allocator = allocator,
        .headers = try std.ArrayList(Header).initCapacity(allocator, 8),
        .headers_sent = false,
        .status_code = 200,
        .writer = writer,
    };
}

pub fn deinit(self: *HttpResponse) void {
    self.headers.deinit(self.allocator);
}

/// set status code of response
pub fn status(self: *HttpResponse, code: u16) void {
    self.status_code = code;
}

/// Add header
pub fn setHeader(self: *HttpResponse, key: []const u8, value: []const u8) !void {
    try self.headers.append(self.allocator, .{ .key = key, .value = value });
}

pub fn json(self: *HttpResponse, body: anytype) !void {
    try self.setHeader("Content-Type", "application/json");

    var string = std.Io.Writer.Allocating.init(self.allocator);
    defer string.deinit();

    var stringifier = std.json.Stringify{ .writer = &string.writer, .options = .{ .whitespace = .indent_2 } };
    try stringifier.write(body);

    try self.send(string.writer.buffered());
}

pub fn send(self: *HttpResponse, content: []const u8) !void {
    if (self.headers_sent) return error.ResponseAlreadySent;

    const status_text = switch (self.status_code) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        404 => "Not Found",
        408 => "Connection Timed Out",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    try self.writer.print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_text });

    try self.writer.print("Content-Length: {d}\r\n", .{content.len});
    try self.writer.writeAll("Connection: keep-alive\r\n");

    for (self.headers.items) |header| {
        try self.writer.print("{s}: {s}\r\n", .{ header.key, header.value });
    }

    // done with header
    try self.writer.writeAll("\r\n");

    // write body
    try self.writer.writeAll(content);
    try self.writer.writeAll("\r\n");

    try self.writer.flush();
    self.headers_sent = true;
}
