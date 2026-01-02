const std = @import("std");

pub const StatusCode = enum(u16) {
    OK = 200,
    Created = 201,
    BadRequest = 400,
    NotFound = 404,
    UnknownMethod = 405,
    ConnectionTimedOut = 408,
    RequestHeaderTooLarge = 431,
    InternalServerError = 500,

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .OK => "OK",
            .Created => "Created",
            .BadRequest => "Bad Request",
            .NotFound => "Not Found",
            .UnknownMethod => "Unknown Method",
            .ConnectionTimedOut => "Connection Timed Out",
            .InternalServerError => "Internal Server Error",
            .RequestHeaderTooLarge => "Request Header Too Large",
        };
    }
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    UNKNOWN,
};

pub const HttpVersion = enum {
    Http1_0,
    Http1_1,
    Http2,
    Http3,

    pub fn fromString(s: []const u8) !HttpVersion {
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .Http1_1;
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .Http1_0;
        if (std.mem.eql(u8, s, "HTTP/2")) return .Http2;
        if (std.mem.eql(u8, s, "HTTP/3")) return .Http3;
        return error.UnsupportedHttpVersion;
    }

    // convert back to string for printing
    pub fn asString(self: HttpVersion) []const u8 {
        return switch (self) {
            .Http1_0 => "HTTP/1.0",
            .Http1_1 => "HTTP/1.1",
            .Http2 => "HTTP/2",
            .Http3 => "HTTP/3",
        };
    }
};
